import { Effects } from '@react-three/drei';

// One scene-linear pass immediately before the renderer's AgX output transform.
// The constants are deliberately restrained: editorial warmth and separation,
// not a cinematic mood filter.
const EDITORIAL_GRADE_SHADER = {
  name: 'EditorialGrade',
  uniforms: {
    tDiffuse: { value: null },
  },
  vertexShader: /* glsl */ `
    varying vec2 vUv;

    void main() {
      vUv = uv;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    }
  `,
  fragmentShader: /* glsl */ `
    uniform sampler2D tDiffuse;
    varying vec2 vUv;

    const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

    void main() {
      vec4 source = texture2D(tDiffuse, vUv);
      vec3 color = max(source.rgb, vec3(0.0));
      float luminance = dot(color, LUMA);

      // Slightly deepen low/mid values while retaining a soft black floor.
      color = pow(color, vec3(1.15));
      float blackMask = 1.0 - smoothstep(0.025, 0.24, luminance);
      color += vec3(0.0024, 0.0027, 0.0025) * blackMask;

      // Approximately +150 K in warm midtones, with a quieter complementary
      // cool bias for carpet/daylight. Near-neutral whites remain neutral.
      float midtoneMask = smoothstep(0.045, 0.20, luminance)
        * (1.0 - smoothstep(0.58, 0.90, luminance));
      float warmBias = smoothstep(0.0, 0.075, color.r - color.b);
      float coolBias = smoothstep(0.005, 0.075, color.b - color.r);
      color *= mix(
        vec3(1.0),
        vec3(1.05, 1.004, 0.95),
        midtoneMask * warmBias
      );
      color *= mix(
        vec3(1.0),
        vec3(0.94, 0.995, 1.07),
        midtoneMask * coolBias
      );

      float gradedLuminance = dot(color, LUMA);
      color = mix(vec3(gradedLuminance), color, 1.2);

      // A gentle shoulder keeps troffer and glazing structure below clipping.
      float highlightMask = smoothstep(0.44, 1.0, gradedLuminance);
      float shoulder = 1.0 / (1.0 + 0.14 * gradedLuminance);
      color *= mix(1.0, shoulder, highlightMask);

      gl_FragColor = vec4(color, source.a);
      #include <tonemapping_fragment>
      #include <colorspace_fragment>
    }
  `,
};

export default function EditorialGrade() {
  return (
    <Effects
      disableGamma
      depthBuffer
      multisamping={2}
      stencilBuffer={false}
    >
      <shaderPass args={[EDITORIAL_GRADE_SHADER]} />
    </Effects>
  );
}
