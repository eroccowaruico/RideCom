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

typedef enum RideComRTCDescriptionKind {
  RideComRTCDescriptionOffer,
  RideComRTCDescriptionAnswer,
} RideComRTCDescriptionKind;

typedef void (*RideComRTCDescriptionCompletion)(void* context, bool success);

// Creation returns an owned handle, or NULL if the operation fails.
// The caller releases each handle once and serializes use against its release.
RIDECOM_RTC_EXPORT RideComRTCFactory* RideComRTCFactoryCreate(void);
RIDECOM_RTC_EXPORT void RideComRTCFactoryRelease(RideComRTCFactory* factory);

RIDECOM_RTC_EXPORT RideComRTCPeer* RideComRTCPeerCreate(RideComRTCFactory* factory);
// Closes the connection before releasing the handle. Open channel handles can
// still be released afterwards.
RIDECOM_RTC_EXPORT void RideComRTCPeerRelease(RideComRTCPeer* peer);

// The local operation creates the offer or answer appropriate to the current
// signaling state. Each operation calls its completion once, possibly before
// returning. The completion must not call back into the adapter.
RIDECOM_RTC_EXPORT void RideComRTCPeerSetLocalDescription(
    RideComRTCPeer* peer, void* context, RideComRTCDescriptionCompletion completion);
RIDECOM_RTC_EXPORT void RideComRTCPeerSetRemoteDescription(
    RideComRTCPeer* peer, RideComRTCDescriptionKind kind, const char* sdp,
    void* context, RideComRTCDescriptionCompletion completion);
RIDECOM_RTC_EXPORT bool RideComRTCPeerHasGatheredCandidates(RideComRTCPeer* peer);
// Copy the current local SDP, including candidates gathered so far. Release a
// non-null result with RideComRTCDescriptionRelease.
RIDECOM_RTC_EXPORT char* RideComRTCPeerCopyLocalDescription(RideComRTCPeer* peer);
RIDECOM_RTC_EXPORT void RideComRTCDescriptionRelease(char* sdp);

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
