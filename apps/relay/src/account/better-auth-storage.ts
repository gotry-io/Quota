import type { SecondaryStorage } from "better-auth";
import { SecretHasher } from "../security.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export class D1EncryptedAuthStorage implements SecondaryStorage {
  readonly #hasher: SecretHasher;
  readonly #encryptionKey: Promise<CryptoKey>;

  constructor(
    private readonly database: D1Database,
    secret: string,
  ) {
    this.#hasher = new SecretHasher(secret);
    this.#encryptionKey = importEncryptionKey(secret);
  }

  async get(key: string): Promise<string | null> {
    const keyHash = await this.#keyHash(key);
    const row = await this.database
      .prepare(
        `SELECT value_ciphertext FROM auth_session_store
         WHERE key_hash = ?1 AND expires_at > ?2`,
      )
      .bind(keyHash, new Date().toISOString())
      .first<{ value_ciphertext: string }>();
    return row ? await this.#decrypt(row.value_ciphertext, keyHash) : null;
  }

  async getAndDelete(key: string): Promise<string | null> {
    const keyHash = await this.#keyHash(key);
    const [selected] = await this.database.batch([
      this.database
        .prepare(
          "SELECT value_ciphertext FROM auth_session_store WHERE key_hash = ?1 AND expires_at > ?2",
        )
        .bind(keyHash, new Date().toISOString()),
      this.database.prepare("DELETE FROM auth_session_store WHERE key_hash = ?1").bind(keyHash),
    ]);
    const row = selected?.results[0] as { value_ciphertext?: unknown } | undefined;
    return typeof row?.value_ciphertext === "string"
      ? await this.#decrypt(row.value_ciphertext, keyHash)
      : null;
  }

  async set(key: string, value: string, ttl = 90 * 24 * 60 * 60): Promise<void> {
    const keyHash = await this.#keyHash(key);
    const ciphertext = await this.#encrypt(value, keyHash);
    const expiresAt = new Date(Date.now() + Math.max(1, ttl) * 1000).toISOString();
    await this.database
      .prepare(
        `INSERT INTO auth_session_store (key_hash, value_ciphertext, expires_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(key_hash) DO UPDATE SET
           value_ciphertext = excluded.value_ciphertext,
           expires_at = excluded.expires_at`,
      )
      .bind(keyHash, ciphertext, expiresAt)
      .run();
  }

  async delete(key: string): Promise<void> {
    await this.database
      .prepare("DELETE FROM auth_session_store WHERE key_hash = ?1")
      .bind(await this.#keyHash(key))
      .run();
  }

  #keyHash(key: string): Promise<string> {
    return this.#hasher.hash("better-auth-storage", key);
  }

  async #encrypt(value: string, keyHash: string): Promise<string> {
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce, additionalData: encoder.encode(keyHash) },
      await this.#encryptionKey,
      encoder.encode(value),
    );
    return `${base64Url(nonce)}.${base64Url(new Uint8Array(ciphertext))}`;
  }

  async #decrypt(value: string, keyHash: string): Promise<string> {
    const [nonceValue, ciphertextValue] = value.split(".");
    if (!nonceValue || !ciphertextValue) throw new Error("Invalid auth storage value");
    const plaintext = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: fromBase64Url(nonceValue),
        additionalData: encoder.encode(keyHash),
      },
      await this.#encryptionKey,
      fromBase64Url(ciphertextValue),
    );
    return decoder.decode(plaintext);
  }
}

async function importEncryptionKey(secret: string): Promise<CryptoKey> {
  if (secret.length < 32) throw new Error("Auth storage key must contain at least 32 characters");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(`quota:better-auth-secondary-storage:v1:${secret}`),
  );
  return crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromBase64Url(value: string): Uint8Array<ArrayBuffer> {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/");
  const binary = atob(`${normalized}${"=".repeat((4 - (normalized.length % 4)) % 4)}`);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}
