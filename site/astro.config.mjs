import { defineConfig } from 'astro/config';

// Static site, served by a Cloudflare Worker from dist/ (see ../wrangler.jsonc).
export default defineConfig({
  site: 'https://depotticker.com',
  trailingSlash: 'always',
});
