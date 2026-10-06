# Third-party notices

First-party app and MCP code is MIT licensed by Charlie Ellington. Dependencies and adapted code keep their original terms. The following notices are preserved in `licenses/` and, for the native app, bundled as `ThirdPartyNotices.txt`.

| Component | Use | Notice/source |
| --- | --- | --- |
| Tremor Dashboard template / Tremor Raw | Fictional demo and bundled screenshots derived from the dashboard template | [MIT, Tremor Labs](licenses/Tremor-MIT.txt); [upstream](https://blocks.tremor.so/templates) |
| Remix Icon 4.6.0 | Icons in the fictional demo and regenerated screenshots | [Apache 2.0](licenses/RemixIcon-Apache-2.0.txt); [upstream](https://github.com/Remix-Design/RemixIcon/tree/v4.6.0) |
| marked 12.0.2 | Bundled Markdown renderer | [MIT](licenses/marked-MIT.txt); [upstream](https://github.com/markedjs/marked/tree/v12.0.2) |
| highlight.js 11.9.0 | Bundled syntax highlighter | [BSD 3-Clause](licenses/highlightjs-BSD-3-Clause.txt); [upstream](https://github.com/highlightjs/highlight.js/tree/11.9.0) |
| Swifter revision `1e4f51c92d7ca486242d8bf0722b99de2c3531aa` | Native local HTTP API | [MIT](licenses/Swifter-MIT.txt); [upstream](https://github.com/httpswift/swifter) |
| Sparkle 2.9.1 | Official updater integration; inactive in local/fork builds | [Sparkle and bundled component notices](licenses/Sparkle-notices.txt); [upstream](https://github.com/sparkle-project/Sparkle/tree/2.9.1) |

The npm and pnpm lockfiles identify additional dependencies fetched during installation. Their packages contain their own notices, including the MCP SDK, Sharp/libvips, Zod, TypeScript and the demo's Next.js/React/Tailwind, chart, table, icon and component libraries. Preserve those notices when distributing a bundled app or package. This repository does not vendor `node_modules`, Swift dependency checkouts or binary frameworks.

The original demo template MIT notice is also retained at `demo-app/LICENSE.md`. Fictional demo content is illustrative and has no connection to actual customers. Third-party brand names describe compatibility and provenance; no endorsement is implied.
