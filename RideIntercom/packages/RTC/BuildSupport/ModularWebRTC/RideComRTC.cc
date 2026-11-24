#include "include/RideComRTC.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <span>
#include <string_view>
#include <utility>

#include "api/create_modular_peer_connection_factory.h"
#include "api/data_channel_interface.h"
#include "api/jsep.h"
#include "api/make_ref_counted.h"
#include "api/peer_connection_interface.h"
#include "api/sctp_transport_interface.h"
#include "api/set_local_description_observer_interface.h"
#include "api/set_remote_description_observer_interface.h"
#include "rtc_base/copy_on_write_buffer.h"
#include "rtc_base/network_constants.h"
#include "rtc_base/thread.h"

namespace {

constexpr size_t kMaximumPacketBytes = 48 * 1024;
constexpr uint64_t kMaximumControlQueueBytes = 64 * 1024;

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

class DescriptionResult {
 public:
  DescriptionResult(void* context, RideComRTCDescriptionCompletion completion)
      : context_(context), completion_(completion) {}
  DescriptionResult(const DescriptionResult&) = delete;
  DescriptionResult& operator=(const DescriptionResult&) = delete;
  ~DescriptionResult() { Finish(false); }

  void Finish(bool success) {
    if (auto completion = std::exchange(completion_, nullptr)) {
      completion(context_, success);
    }
  }

 private:
  void* context_;
  RideComRTCDescriptionCompletion completion_;
};

class LocalDescriptionObserver : public webrtc::SetLocalDescriptionObserverInterface {
 public:
  LocalDescriptionObserver(void* context, RideComRTCDescriptionCompletion completion)
      : result_(context, completion) {}

  void OnSetLocalDescriptionComplete(webrtc::RTCError error) override { result_.Finish(error.ok()); }

 private:
  DescriptionResult result_;
};

class RemoteDescriptionObserver : public webrtc::SetRemoteDescriptionObserverInterface {
 public:
  RemoteDescriptionObserver(void* context, RideComRTCDescriptionCompletion completion)
      : result_(context, completion) {}

  void OnSetRemoteDescriptionComplete(webrtc::RTCError error) override { result_.Finish(error.ok()); }

 private:
  DescriptionResult result_;
};

class ChannelObserver final : public webrtc::DataChannelObserver {
 public:
  ChannelObserver(void* context, RideComRTCChannelStateChanged state_changed,
                  RideComRTCChannelReceived received)
      : context_(context), state_changed_(state_changed), received_(received) {}

  void OnStateChange() override {
    if (state_changed_) {
      state_changed_(context_);
    }
  }

  void OnMessage(const webrtc::DataBuffer& buffer) override {
    if (received_ && buffer.binary && buffer.size() > 0 && buffer.size() <= kMaximumPacketBytes) {
      received_(context_, buffer.data.data(), buffer.size());
    }
  }

 private:
  void* context_;
  RideComRTCChannelStateChanged state_changed_;
  RideComRTCChannelReceived received_;
};

bool HasOnlyDataChannelMedia(std::string_view sdp) {
  bool has_media = false;
  while (!sdp.empty()) {
    const size_t end = sdp.find_first_of("\r\n");
    const std::string_view line = sdp.substr(0, end);
    if (line.starts_with("m=")) {
      if (!line.starts_with("m=application ")) {
        return false;
      }
      has_media = true;
    }
    if (end == std::string_view::npos) {
      break;
    }
    sdp.remove_prefix(end + 1);
  }
  return has_media;
}

}  // namespace

struct RideComRTCFactory {
  std::shared_ptr<Factory> handle;
};

struct RideComRTCPeer {
  std::shared_ptr<Peer> handle;
};

struct RideComRTCChannel {
  void ClearObserver() {
    if (observer) {
      native->UnregisterObserver();
      observer.reset();
    }
  }

  std::shared_ptr<Peer> peer;
  webrtc::scoped_refptr<webrtc::DataChannelInterface> native;
  bool reliable;
  std::unique_ptr<ChannelObserver> observer;
};

RideComRTCFactory* RideComRTCFactoryCreate(bool include_loopback) {
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
  if (include_loopback) {
    webrtc::PeerConnectionFactoryInterface::Options options;
    options.network_ignore_mask &= ~webrtc::ADAPTER_TYPE_LOOPBACK;
    factory->native->SetOptions(options);
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

void RideComRTCPeerSetLocalDescription(
    RideComRTCPeer* peer, void* context, RideComRTCDescriptionCompletion completion) {
  if (!completion) {
    return;
  }
  if (!peer) {
    completion(context, false);
    return;
  }
  peer->handle->native->SetLocalDescription(
      webrtc::make_ref_counted<LocalDescriptionObserver>(context, completion));
}

void RideComRTCPeerSetRemoteDescription(
    RideComRTCPeer* peer, RideComRTCDescriptionKind kind, const char* sdp,
    void* context, RideComRTCDescriptionCompletion completion) {
  if (!completion) {
    return;
  }
  if (!peer || !sdp || !HasOnlyDataChannelMedia(sdp) ||
      (kind != RideComRTCDescriptionOffer && kind != RideComRTCDescriptionAnswer)) {
    completion(context, false);
    return;
  }
  const auto type = kind == RideComRTCDescriptionOffer ? webrtc::SdpType::kOffer : webrtc::SdpType::kAnswer;
  auto description = webrtc::CreateSessionDescription(type, sdp);
  if (!description) {
    completion(context, false);
    return;
  }
  peer->handle->native->SetRemoteDescription(
      std::move(description), webrtc::make_ref_counted<RemoteDescriptionObserver>(context, completion));
}

bool RideComRTCPeerHasGatheredCandidates(RideComRTCPeer* peer) {
  return peer && peer->handle->native->ice_gathering_state() == webrtc::PeerConnectionInterface::kIceGatheringComplete;
}

char* RideComRTCPeerCopyLocalDescription(RideComRTCPeer* peer) {
  if (!peer) {
    return nullptr;
  }
  return peer->handle->factory->signaling->BlockingCall([&] {
    const auto* description = peer->handle->native->local_description();
    return description ? strdup(description->ToString().c_str()) : nullptr;
  });
}

void RideComRTCDescriptionRelease(char* sdp) {
  std::free(sdp);
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
  return new RideComRTCChannel{peer->handle, channel.MoveValue(), reliable, nullptr};
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

uint64_t RideComRTCChannelBufferedBytes(RideComRTCChannel* channel) {
  return channel ? channel->native->buffered_amount() : 0;
}

bool RideComRTCChannelSend(RideComRTCChannel* channel, const uint8_t* bytes, size_t length) {
  if (!channel || !bytes || length == 0 || length > kMaximumPacketBytes) {
    return false;
  }
  return channel->peer->factory->signaling->BlockingCall([&] {
    const uint64_t queue_limit = channel->reliable ? kMaximumControlQueueBytes : 0;
    if (channel->native->state() != webrtc::DataChannelInterface::kOpen ||
        channel->native->buffered_amount() > queue_limit) {
      return false;
    }
    const std::span<const uint8_t> packet(bytes, length);
    return channel->native->Send(webrtc::DataBuffer(webrtc::CopyOnWriteBuffer(packet), true));
  });
}

void RideComRTCChannelObserve(
    RideComRTCChannel* channel, void* context, RideComRTCChannelStateChanged state_changed,
    RideComRTCChannelReceived received) {
  if (!channel) {
    return;
  }
  channel->peer->factory->signaling->BlockingCall([&] {
    channel->ClearObserver();
    if (state_changed || received) {
      channel->observer = std::make_unique<ChannelObserver>(context, state_changed, received);
      channel->native->RegisterObserver(channel->observer.get());
    }
  });
}

void RideComRTCChannelRelease(RideComRTCChannel* channel) {
  if (channel) {
    channel->ClearObserver();
    channel->native->Close();
    delete channel;
  }
}
