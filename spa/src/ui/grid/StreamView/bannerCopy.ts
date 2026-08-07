import type { StreamBannerState, StreamExitReason } from '../../../three/streamClient';
import { exitReasonCopy } from './exitReason';

// ---------------------------------------------------------------------------
//  bannerCopy — the connection banner's words, as a pure derivation.
//
//  'reconnecting' shows the cause-specific disconnect line; a 'spotty' banner
//  while the LOCAL device is throttled is relabelled "Device under load" so a
//  client-side stall is not mislabelled a network problem.
// ---------------------------------------------------------------------------
export function bannerCopy({
  restoreReconnect, restoring, bannerState, decoderUnsupported, deviceUnderLoad, exitReason,
}: {
  restoreReconnect: boolean;
  restoring: boolean;
  bannerState: StreamBannerState | null;
  decoderUnsupported: boolean;
  deviceUnderLoad: boolean;
  exitReason: StreamExitReason | null;
}): { bannerText: string; bannerIsDevice: boolean } {
  const bannerText =
    restoreReconnect
      ? (restoring ? 'Restoring…' : 'Reconnecting…')
      : decoderUnsupported
      ? "This browser can't play the live stream — the required video decoder (WebCodecs) or codec isn't supported. Open the gallery in Chrome, or on a desktop browser."
      : bannerState === 'reconnecting'
      ? (exitReasonCopy(exitReason) ?? 'Reconnecting…')
      : deviceUnderLoad
        ? 'Device under load'
        : 'Spotty connection';
  return { bannerText, bannerIsDevice: bannerState === 'spotty' && deviceUnderLoad };
}
