import type { Metadata } from "next"
import { ThemeProvider } from "next-themes"
import "./globals.css"
import { siteConfig } from "./siteConfig"

import { Sidebar } from "@/components/ui/navigation/Sidebar"


export const metadata: Metadata = {
  metadataBase: new URL("http://localhost:3000"),
  title: siteConfig.name,
  description: siteConfig.description,
  keywords: [],
  authors: [
    {
      name: "Design Canvas",
      url: "",
    },
  ],
  creator: "Design Canvas",
  openGraph: {
    type: "website",
    locale: "en_US",
    url: siteConfig.url,
    title: siteConfig.name,
    description: siteConfig.description,
    siteName: siteConfig.name,
  },
  icons: {
    icon: "/favicon.ico",
  },
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        className={` overflow-y-scroll scroll-auto antialiased selection:bg-indigo-100 selection:text-indigo-700 dark:bg-gray-950`}
        suppressHydrationWarning
      >
        <div className="mx-auto max-w-screen-2xl">
          <ThemeProvider defaultTheme="dark" forcedTheme="dark" attribute="class">
            <Sidebar />
            <main className="lg:pl-72">{children}</main>
          </ThemeProvider>
        </div>
      </body>
    </html>
  )
}
