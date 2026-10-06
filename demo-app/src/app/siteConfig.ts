export const siteConfig = {
  name: "Demo App",
  url: "http://localhost:3000",
  description: "A sample SaaS dashboard for Design Canvas.",
  baseLinks: {
    home: "/",
    overview: "/overview",
    details: "/details",
    settings: {
      general: "/settings/general",
      billing: "/settings/billing",
      users: "/settings/users",
    },
  },
}

export type siteConfig = typeof siteConfig
