#ifndef QUOTABAR_KEYCHAIN_SHIM_H
#define QUOTABAR_KEYCHAIN_SHIM_H

#include <Security/SecBase.h>

OSStatus quotabar_copy_generic_password_status(const char *service, const char *account);

#endif
