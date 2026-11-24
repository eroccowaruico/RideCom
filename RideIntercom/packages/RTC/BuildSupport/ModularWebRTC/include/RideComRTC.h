#ifndef RIDECOM_RTC_H
#define RIDECOM_RTC_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RIDECOM_RTC_EXPORT __attribute__((visibility("default")))

typedef struct RideComRTCFactory RideComRTCFactory;
typedef struct RideComRTCPeer RideComRTCPeer;
typedef struct RideComRTCChannel RideComRTCChannel;

typedef enum RideComRTCChannelState {
  RideComRTCChannelConnecting,
  RideComRTCChannelOpen,
  RideComRTCChannelClosing,
  RideComRTCChannelClosed,
} RideComRTCChannelState;

// Creation returns an owned handle, or NULL if the operation fails.
// The caller releases each handle once and serializes use against its release.
RIDECOM_RTC_EXPORT RideComRTCFactory* RideComRTCFactoryCreate(void);
RIDECOM_RTC_EXPORT void RideComRTCFactoryRelease(RideComRTCFactory* factory);

RIDECOM_RTC_EXPORT RideComRTCPeer* RideComRTCPeerCreate(RideComRTCFactory* factory);
// Closes the connection before releasing the handle. Open channel handles can
// still be released afterwards.
RIDECOM_RTC_EXPORT void RideComRTCPeerRelease(RideComRTCPeer* peer);

// Channel IDs are allocated out of band. Unreliable channels are unordered and
// have zero retransmissions.
RIDECOM_RTC_EXPORT RideComRTCChannel* RideComRTCChannelCreate(
    RideComRTCPeer* peer, const char* label, int32_t id, bool reliable);
RIDECOM_RTC_EXPORT RideComRTCChannelState RideComRTCChannelGetState(RideComRTCChannel* channel);
RIDECOM_RTC_EXPORT void RideComRTCChannelRelease(RideComRTCChannel* channel);

#undef RIDECOM_RTC_EXPORT

#ifdef __cplusplus
}
#endif

#endif
