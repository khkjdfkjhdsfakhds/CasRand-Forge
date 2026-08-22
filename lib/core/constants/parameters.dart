const models = [
  'nai-diffusion-5-full',
  'nai-diffusion-5-curated',
  'nai-diffusion-4-5-full',
  'nai-diffusion-4-5-curated',
  'nai-diffusion-4-full',
  'nai-diffusion-4-curated-preview',
  'nai-diffusion-3',
  'nai-diffusion-furry-3'
];
const samplers = [
  'k_euler',
  'k_euler_ancestral',
  'k_dpmpp_2s_ancestral',
  'k_dpmpp_2m_sde',
  'k_dpmpp_sde',
  'k_dpmpp_2m',
  'ddim_v3'
];
const samplersV4 = [
  'k_euler',
  'k_euler_ancestral',
  'k_dpmpp_2s_ancestral',
  'k_dpmpp_2m_sde',
  'k_dpmpp_sde',
  'k_dpmpp_2m',
];
const noiseSchedules = [
  'native',
  'karras',
  'exponential',
  'polyexponential',
];
const noiseSchedulesV4 = [
  'karras',
  'exponential',
  'polyexponential',
];

const List<String> commentKeys = [
  'uc',
  'scale',
  'sampler',
  'steps',
  'n_samples',
  'ucPreset',
  'qualityToggle',
  'sm',
  'sm_dyn',
  'dynamic_thresholding',
  'controlnet_strength',
  'legacy',
  'add_original_image',
  'uncond_scale',
  'cfg_rescale',
  'noise_schedule',
  'deliberate_euler_ancestral_bug',
  'prefer_brownian',
  'straight_alpha',
  'tag_hint_qt',
  'tag_hint_uc_preset',
  'negative_prompt',
  'seed',
  'use_coords',
];

/// Inpainting model variants, matching the official web frontend.
const Map<String, String> inpaintModelMapping = {
  'nai-diffusion-5-full': 'nai-diffusion-5-full-inpainting',
  // Curated V5 temporarily uses the V4.5 Curated inpainting endpoint.
  'nai-diffusion-5-curated': 'nai-diffusion-4-5-curated-inpainting',
  'nai-diffusion-4-5-full': 'nai-diffusion-4-5-full-inpainting',
  'nai-diffusion-4-5-curated': 'nai-diffusion-4-5-curated-inpainting',
  'nai-diffusion-4-full': 'nai-diffusion-4-full-inpainting',
  'nai-diffusion-4-curated-preview': 'nai-diffusion-4-curated-inpainting',
  'nai-diffusion-3': 'nai-diffusion-3-inpainting',
  'nai-diffusion-furry-3': 'nai-diffusion-furry-3-inpainting',
};

const Map<String, String> sourceToModel = {
  'Stable Diffusion XL C1E1DE52': 'nai-diffusion-3',
  'Stable Diffusion XL 7BCCAA2C': 'nai-diffusion-3',
  'Stable Diffusion XL 9CC2F394': 'nai-diffusion-furry-3',
  'NovelAI Diffusion V4 F6E18726': 'nai-diffusion-4-curated-preview',
  'NovelAI Diffusion V4 79F47848': 'nai-diffusion-4-full',
  'NovelAI Diffusion V4.5 4BDE2A90': 'nai-diffusion-4-5-full',
  'NovelAI Diffusion V4.5 B9F340FD': 'nai-diffusion-4-5-full',
  'NovelAI Diffusion V4.5 B5A2A797': 'nai-diffusion-4-5-full',
  'NovelAI Diffusion V4.5 C02D4F98': 'nai-diffusion-4-5-curated',
};
