/* SPDX-License-Identifier: MIT
 *
 * Copyright (C) 2018-2023 WireGuard LLC. All Rights Reserved.
 */

#ifndef WIREGUARD_H
#define WIREGUARD_H

#include <sys/types.h>
#include <stdint.h>
#include <stdbool.h>

typedef void(*logger_fn_t)(void *context, int level, const char *msg);
extern void wgSetLogger(void *context, logger_fn_t logger_fn);
extern int wgTurnOn(const char *settings, int32_t tun_fd);
extern void wgTurnOff(int handle);
extern int64_t wgSetConfig(int handle, const char *settings);
extern char *wgGetConfig(int handle);
extern void wgBumpSockets(int handle);
extern void wgDisableSomeRoamingForBrokenMobileSemantics(int handle);
extern const char *wgVersion();
/* VayuSetu: DNS interception in front of WireGuard. Configure before wgTurnOn; NULL or empty disables. */
extern int32_t wgDNSConfigure(const char *settings);
extern void wgDNSReload(void);
extern char *wgDNSStats(void);
/* VayuSetu: shared encrypted-DNS upstream client for the local DNS-only tunnel. */
extern int32_t wgDNSUpstreamOpen(const char *settings);
extern int wgDNSUpstreamExchange(int32_t handle, const unsigned char *query, int queryLength, unsigned char *out, int outCapacity);
extern void wgDNSUpstreamClose(int32_t handle);

#endif
