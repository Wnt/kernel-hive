import type { OSBinding } from '../../../three/archetypeRegistry';
import { S } from './styles';

// ---------------------------------------------------------------------------
//  Poster / note card for non-streamable transports (showcase)
// ---------------------------------------------------------------------------
export function PosterCard({
  os,
  displayName,
  note,
}: {
  os: OSBinding;
  displayName: string;
  note: string;
}) {
  const accent = os.accentColor || '#8891a6';
  // The badge text is the OS accent PULLED TOWARDS INK: accents are chosen for
  // identity, not for contrast, and several (Amstrad yellow, Android green) are
  // unreadable at full strength on the gallery's paper. The rule keeps them
  // recognisable while staying legible.
  return (
    <div style={{ ...S.poster, boxShadow: `inset 0 0 140px ${accent}18` }}>
      <div
        style={{
          ...S.posterBadge,
          borderColor: accent,
          color: `color-mix(in srgb, ${accent} 62%, var(--ink))`,
        }}
      >
        {os.osId}
      </div>
      <h2 style={S.posterTitle}>{displayName}</h2>
      <p style={S.posterEra}>{os.eraLabel}</p>
      <p style={S.posterNote}>{note}</p>
    </div>
  );
}
