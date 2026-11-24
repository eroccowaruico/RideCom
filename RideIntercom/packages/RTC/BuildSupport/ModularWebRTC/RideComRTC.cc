#include "include/RideComRTC.h"

#include <memory>
#include <utility>

#include "api/create_modular_peer_connection_factory.h"
#include "api/data_channel_interface.h"
#include "api/peer_connection_interface.h"
#include "api/sctp_transport_interface.h"
#include "rtc_base/thread.h"

namespace {

struct Factory {
  std::unique_ptr<webrtc::Thread> network = webrtc::Thread::CreateWithSocketServer();
  std::unique_ptr<webrtc::Thread> signaling = webrtc::Thread::Create();
  webrtc::scoped_refptr<webrtc::PeerConnectionFactoryInterface> native;
};

class PeerObserver final : public webrtc::PeerConnectionObserver {
 public:
  explicit PeerObserver(webrtc::Thread& signaling) : signaling_(signaling) {}

  void OnSignalingChange(webrtc::PeerConnectionInterface::SignalingState) override {}
  void OnIceGatheringChange(webrtc::PeerConnectionInterface::IceGatheringState) override {}
  void OnIceCandidate(const webrtc::IceCandidate*) override {}

  void OnDataChannel(webrtc::scoped_refptr<webrtc::DataChannelInterface> channel) override {
    // Only a negotiated channel may be owned by the application.
    signaling_.PostTask([channel = std::move(channel)] { channel->Close(); });
  }

 private:
  webrtc::Thread& signaling_;
};

struct Peer {
  explicit Peer(std::shared_ptr<Factory> owner)
      : factory(std::move(owner)), observer(*factory->signaling) {}

  // Members are destroyed in reverse order. The observer and threads must
  // outlive the native connection and any remaining channel handles.
  std::shared_ptr<Factory> factory;
  PeerObserver observer;
  webrtc::scoped_refptr<webrtc::PeerConnectionInterface> native;
};

}  // namespace

struct RideComRTCFactory {
  std::shared_ptr<Factory> handle;
};

struct RideComRTCPeer {
  std::shared_ptr<Peer> handle;
};

struct RideComRTCChannel {
  std::shared_ptr<Peer> peer;
  webrtc::scoped_refptr<webrtc::DataChannelInterface> native;
};

RideComRTCFactory* RideComRTCFactoryCreate(void) {
  auto factory = std::make_shared<Factory>();
  if (!factory->network->Start() || !factory->signaling->Start()) {
    return nullptr;
  }
  webrtc::PeerConnectionFactoryDependencies dependencies;
  dependencies.network_thread = factory->network.get();
  dependencies.signaling_thread = factory->signaling.get();
  factory->native = webrtc::CreateModularPeerConnectionFactory(std::move(dependencies));
  if (!factory->native) {
    return nullptr;
  }
  return new RideComRTCFactory{std::move(factory)};
}

void RideComRTCFactoryRelease(RideComRTCFactory* factory) {
  delete factory;
}

RideComRTCPeer* RideComRTCPeerCreate(RideComRTCFactory* factory) {
  if (!factory) {
    return nullptr;
  }
  auto peer = std::make_shared<Peer>(factory->handle);
  webrtc::PeerConnectionInterface::RTCConfiguration configuration;
  configuration.tcp_candidate_policy = webrtc::PeerConnectionInterface::kTcpCandidatePolicyDisabled;
  auto connection = peer->factory->native->CreatePeerConnectionOrError(
      configuration, webrtc::PeerConnectionDependencies(&peer->observer));
  if (!connection.ok()) {
    return nullptr;
  }
  peer->native = connection.MoveValue();
  return new RideComRTCPeer{std::move(peer)};
}

void RideComRTCPeerRelease(RideComRTCPeer* peer) {
  if (peer) {
    peer->handle->native->Close();
    delete peer;
  }
}

RideComRTCChannel* RideComRTCChannelCreate(
    RideComRTCPeer* peer, const char* label, int32_t id, bool reliable) {
  if (!peer || !label || id < 0 || id > webrtc::kMaxSctpSid) {
    return nullptr;
  }
  webrtc::DataChannelInit configuration;
  configuration.negotiated = true;
  configuration.id = id;
  configuration.ordered = reliable;
  if (!reliable) {
    configuration.maxRetransmits = 0;
  }
  auto channel = peer->handle->native->CreateDataChannelOrError(label, &configuration);
  if (!channel.ok()) {
    return nullptr;
  }
  return new RideComRTCChannel{peer->handle, channel.MoveValue()};
}

RideComRTCChannelState RideComRTCChannelGetState(RideComRTCChannel* channel) {
  using DataChannel = webrtc::DataChannelInterface;
  if (channel) {
    switch (channel->native->state()) {
      case DataChannel::kConnecting: return RideComRTCChannelConnecting;
      case DataChannel::kOpen: return RideComRTCChannelOpen;
      case DataChannel::kClosing: return RideComRTCChannelClosing;
      case DataChannel::kClosed: break;
    }
  }
  return RideComRTCChannelClosed;
}

void RideComRTCChannelRelease(RideComRTCChannel* channel) {
  if (channel) {
    channel->native->Close();
    delete channel;
  }
}
