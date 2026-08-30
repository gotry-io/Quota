#include "QuotaBarKeychainShim.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

OSStatus quotabar_copy_generic_password_status(const char *service, const char *account) {
  Boolean previousAllowed = true;
  OSStatus status = errSecParam;
  CFStringRef serviceRef = NULL;
  CFStringRef accountRef = NULL;
  CFDictionaryRef query = NULL;
  CFTypeRef result = NULL;

  if (service == NULL || account == NULL) {
    return errSecParam;
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  (void)SecKeychainGetUserInteractionAllowed(&previousAllowed);
  (void)SecKeychainSetUserInteractionAllowed(false);
#pragma clang diagnostic pop

  serviceRef = CFStringCreateWithCString(kCFAllocatorDefault, service, kCFStringEncodingUTF8);
  accountRef = CFStringCreateWithCString(kCFAllocatorDefault, account, kCFStringEncodingUTF8);
  if (serviceRef != NULL && accountRef != NULL) {
    const void *keys[] = {
        kSecClass,
        kSecAttrService,
        kSecAttrAccount,
        kSecMatchLimit,
        kSecReturnData,
    };
    const void *values[] = {
        kSecClassGenericPassword,
        serviceRef,
        accountRef,
        kSecMatchLimitOne,
        kCFBooleanTrue,
    };
    query = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        sizeof(keys) / sizeof(keys[0]),
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (query != NULL) {
      status = SecItemCopyMatching(query, &result);
      if (result != NULL) {
        CFRelease(result);
        result = NULL;
      }
      CFRelease(query);
    }
  }

  if (accountRef != NULL) {
    CFRelease(accountRef);
  }
  if (serviceRef != NULL) {
    CFRelease(serviceRef);
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  (void)SecKeychainSetUserInteractionAllowed(previousAllowed);
#pragma clang diagnostic pop

  return status;
}
