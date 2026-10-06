// Root page — redirects to the main dashboard overview.

import { redirect } from "next/navigation"

export default function Home() {
  redirect("/overview")
}
