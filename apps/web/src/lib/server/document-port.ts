export interface WebDocumentViewer {
  displayLabel: string;
}

export interface WebDocumentPort {
  getViewer(headers: Headers): Promise<WebDocumentViewer | null>;
}
