import RideComRTC

func checkConnectionLifecycle() {
    guard let factory = RideComRTCFactoryCreate(false) else {
        preconditionFailure("Could not create modular WebRTC factory")
    }
    guard let peer = RideComRTCPeerCreate(factory, false) else {
        preconditionFailure("Could not create a data-only peer")
    }
    RideComRTCFactoryRelease(factory)

    precondition(RideComRTCChannelCreate(peer, "invalid", -1, true) == nil)
    guard
        let control = RideComRTCChannelCreate(peer, "control", 0, true),
        let audio = RideComRTCChannelCreate(peer, "audio", 1, false)
    else {
        preconditionFailure("Could not create both negotiated channels")
    }
    precondition(RideComRTCChannelGetState(control) == RideComRTCChannelConnecting)
    precondition(RideComRTCChannelGetState(audio) == RideComRTCChannelConnecting)
    precondition(RideComRTCChannelCreate(peer, "duplicate", 1, false) == nil)

    RideComRTCPeerRelease(peer)
    precondition(RideComRTCChannelGetState(control) == RideComRTCChannelClosed)
    precondition(RideComRTCChannelGetState(audio) == RideComRTCChannelClosed)
    RideComRTCChannelRelease(control)
    RideComRTCChannelRelease(audio)
}

for _ in 0..<3 {
    checkConnectionLifecycle()
}
print("Peer and both negotiated channels released")
