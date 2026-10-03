// @ts-check
import { defineConfig, passthroughImageService } from "astro/config";
import starlight from "@astrojs/starlight";

const clientPort = Number(process.env.DEV_CLIENT_PORT) || undefined;
const allowedHosts = process.env.DEV_ALLOWED_HOSTS?.split(",").filter(Boolean);

export default defineConfig({
  site: process.env.DOCS_SITE || "https://uris.pages.dev",
  image: { service: passthroughImageService() },
  server: allowedHosts ? { host: true, allowedHosts } : {},
  vite: clientPort
    ? {
        server: {
          allowedHosts,
          ws: { clientPort },
          watch: { usePolling: true, interval: 300 },
        },
      }
    : {},
  integrations: [
    starlight({
      title: "uris",
      description:
        "An indexer for personal data. One searchable index across the places your files and records live, with a way back out.",
      favicon: "/icon.svg",
      logo: { src: "./src/assets/mark.svg", alt: "uris" },
      components: { SiteTitle: "./src/components/SiteTitle.astro" },
      customCss: ["./src/styles/global.css"],
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/urisrb/uris",
        },
      ],
      sidebar: [
        {
          label: "Get started",
          items: [
            { label: "Overview", slug: "overview" },
            { label: "Quickstart", slug: "quickstart" },
            { label: "Self-hosting", slug: "guides/self-hosting" },
          ],
        },
        {
          label: "How-to guides",
          items: [
            { label: "Attach a resource", slug: "guides/attach-a-resource" },
            { label: "Reach a tailnet", slug: "guides/tailnet" },
            { label: "Connect an agent", slug: "guides/connect-an-agent" },
            { label: "Ask the catalog", slug: "guides/ask" },
            { label: "Tag items", slug: "guides/tag" },
            { label: "Export your catalog", slug: "guides/export" },
          ],
        },
        {
          label: "Key concepts",
          items: [
            { label: "Feeds", slug: "concepts/feeds" },
            { label: "References", slug: "concepts/references" },
            { label: "Adding things", slug: "concepts/adding" },
            { label: "Analysis", slug: "concepts/analysis" },
            { label: "Resources", slug: "concepts/resources" },
            { label: "Search", slug: "concepts/search" },
            { label: "Agents and MCP", slug: "concepts/agents" },
            { label: "Tenants", slug: "concepts/tenants" },
            { label: "Security", slug: "concepts/security" },
          ],
        },
        {
          label: "Reference",
          items: [
            { label: "GraphQL", slug: "reference/graphql" },
            { label: "MCP tools", slug: "reference/mcp" },
            { label: "Resource types", slug: "reference/resources" },
            { label: "Scopes", slug: "reference/scopes" },
            { label: "ENV vars", slug: "reference/environment" },
          ],
        },
      ],
    }),
  ],
});
