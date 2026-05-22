# OpenClicky Browser Workspace Spec

Reference mockup: `/Users/jkneen/Library/Application Support/OpenClicky/AgentMode/CodexHome/generated_images/019e46fb-1755-7dd2-aab7-1e97caad1128/ig_01581f08b8b8c678016a0e135957ec8191a35586e2a2094b2a.png`

## Product intent

OpenClicky should support a browser workspace that can show real web sites and local web pages while keeping OpenClicky's own chat interface embedded on the right side of the browser. The user should feel like they are working inside a focused research/build browser, not jumping between a browser, a detached HUD, and separate specialist agents.

The key idea from the mockup is a split workspace:

- Left side: normal browser page canvas for remote URLs, local files, docs, previews, and app pages.
- Right side: OpenClicky's own copied chat component, scoped to the current page and current specialist mode.
- Top/side chrome: lightweight browser controls and workspace navigation, with enough room for tabs, URL, local-page labels, and status.

## Goals

1. Let users browse real websites and local pages inside an OpenClicky-owned workspace.
2. Keep OpenClicky's chat interface visible and context-aware without covering the page.
3. Let specialists operate as mode chips/tabs within the side panel instead of becoming separate hidden sessions.
4. Preserve the familiar OpenClicky composer, transcript rows, tool status, attachments, and actions.
5. Make the page and chat feel connected: page context, selected text, screenshots, DOM/article text, local file metadata, and active task state should flow into the right panel.

## Non-goals for the first pass

- Building a full Chrome replacement.
- Supporting every browser extension behavior.
- Multi-profile cookie/account management beyond the embedded WebKit session chosen for OpenClicky.
- Replacing the existing Agent HUD or main panel.
- Running destructive page automation without explicit user action.

## Primary layout

### Window shell

- macOS dark window with rounded corners and subtle border.
- Top bar includes:
  - Browser back/forward/reload.
  - Address/search field.
  - Tab strip for web pages and local pages.
  - Optional compact workspace controls: capture, pin, split, settings.
- Left optional rail includes compact workspace shortcuts: home, pages, bookmarks/history, local files, tasks/settings.

### Page canvas

The page canvas is the main WebView area. It must support:

- Remote URLs.
- `file://` local HTML pages.
- OpenClicky-generated local previews.
- Local docs rendered as HTML when available.
- App preview routes from local dev servers.

The page should remain fully interactive. The chat panel must not steal focus unless the user clicks or invokes the composer.

The embedded WebKit page should identify as a normal desktop Safari browser so sites serve their full desktop experience instead of down-leveling OpenClicky's in-app browser shell.

### Right OpenClicky chat panel

The side panel is not a generic browser sidebar. It is OpenClicky's own chat interface component rendered inside the browser workspace.

Recommended first-pass dimensions:

- Width: 380-460 pt, default 420 pt.
- Min width: 340 pt.
- Max width: 540 pt or 38% of window width.
- Collapsed width: 52-64 pt icon rail.
- Resizable with a subtle drag handle on the left edge.

Panel sections, top to bottom:

1. Header
   - OpenClicky title.
   - Current page/site indicator.
   - Clear chat, close/collapse controls.

2. Page context strip
   - Context status, readable text count, selection state, split state.
   - Current URL/path label.
   - Manual refresh action.

3. Chat transcript
   - Blank by default.
   - Clearable by the user.
   - Threaded user/assistant messages once the user starts chatting.
   - Auto-scroll only when user is already near the bottom.

4. Basic suggestion chips
   - Compact chips only for the first useful page-aware actions:
     - Summarize
     - Key points
     - Search
     - Click
     - Fill

5. Composer
   - Same OpenClicky prompt composer behavior as the main panel/HUD.
   - Multiline wrapping and vertical growth.
   - Shift+Enter inserts newline.
   - Enter sends.
   - Minimal attachment/context buttons only when they are wired to real actions.

## Interaction model

### Opening the workspace

Entrypoints:

- From a URL in chat: “Open in OpenClicky browser”.
- From local HTML/docs: “Preview with OpenClicky”.
- From Connect/specialist surfaces: “Open browser workspace”.
- From Agent result artifacts: open generated page in workspace.
- From current screen/browser context: “Bring this page into OpenClicky”.

### Page-to-chat context

OpenClicky should attach context in layers:

1. Basic metadata: URL, title, favicon, load state.
2. Readable text extraction: article/main content when available.
3. Selection context: selected text, clicked element, visible viewport.
4. Visual context: screenshot of page or visible viewport when needed.
5. Local context: file path, dev server route, project/repo metadata when local.

The panel should show what context is active instead of silently guessing.

### Side chat behavior

The side chat is the first-class browser agent for this workspace. It should work in the current Browser Workspace instance by default, with full access to the active WebKit tab, extracted text, selection, URL, and direct page actions.

- Simple page questions, summaries, key points, navigation, search, click, type, and fill actions happen inline in the side chat.
- The chat starts blank and can be cleared without resetting the browser tab.
- Do not start a background Agent Mode task for ordinary page chat, even when the selected computer-use model is a GPT/Codex model.
- Create an Agent Mode task only when the user explicitly asks for background work, asks for subagents/subtasks, or the request clearly needs longer-running coding, file, or deep research work.

### Local page support

Local web pages are first-class:

- Load `file://` pages with clear local-file labeling.
- Load localhost pages from dev servers.
- Offer reload, open in external browser, reveal in Finder, and copy path/URL.
- For local projects, optionally attach repo root and branch if discoverable.
- Avoid broad filesystem access unless the user asks or selects a folder.

### Privacy and permission prompts

- Web context extraction should be visible through the status strip.
- For sensitive pages, show “context limited” and use explicit capture/extract actions.
- Never store page content in durable memory unless the user asks or the outcome is a stable preference/project fact.
- Local page paths may be shown in the UI, but avoid sending full filesystem trees unless needed.

## Visual design notes from the mockup

- Keep the page canvas visually calm and wide.
- Use dark, frosted, Liquid Glass-style side panel surfaces.
- Purple remains the main OpenClicky accent for active specialists and send controls.
- Use small status dots rather than large banners.
- Cards should have subtle borders, not heavy panels.
- The chat panel should look native to OpenClicky, not like an iframe from another product.
- The side panel can float slightly within the browser shell, but should remain aligned and docked.

## Technical architecture sketch

### Suggested components

- `OpenClickyBrowserWorkspaceWindowManager`
  - Owns the window lifecycle and sizing.
  - Coordinates tabs and split layout.

- `OpenClickyBrowserWorkspaceView`
  - SwiftUI shell for toolbar, tab strip, rail, WebView, and side panel.

- `OpenClickyWorkspaceWebView`
  - WebKit wrapper for remote/local content.
  - Emits page metadata, navigation state, selection state, and snapshots.

- `OpenClickyBrowserChatSidePanel`
  - Reuses the existing OpenClicky chat component where possible.
  - Injects page-scoped context provider and specialist chip bar.

- `OpenClickyWebContextProvider`
  - Converts current page state into compact model context.
  - Handles readable text extraction, selected text, screenshot metadata, and local-page metadata.

- `OpenClickyBrowserSpecialistMode`
  - Defines specialist chip metadata and prompt overlays.

### Reuse existing OpenClicky surfaces

Prefer reusing these existing patterns rather than building new interaction rules:

- Existing chat transcript row styling.
- Existing prompt composer, including multiline behavior and slash/@ autocomplete caps.
- Existing Agent Mode task creation path for long-running work.
- Existing attachment/context chips.
- Existing Liquid Glass or panel backdrop helpers if present.

## MVP phases

### Phase 1: Static workspace shell

Deliver a window with:

- WebView loading remote URLs and local files.
- Right docked chat side panel using placeholder messages.
- Specialist chips as visual-only mode controls.
- Address bar, reload, and basic navigation.

Success criteria:

- A real website and a local HTML file can both be opened.
- The right panel stays docked and resizable.
- Page interactions do not get blocked by chat UI.

### Phase 2: Real OpenClicky chat integration

Deliver:

- Reused OpenClicky composer and transcript.
- Page metadata context card.
- Basic page-aware prompts: summarize, key takeaways, explain terms.
- Current URL/title attached to chat requests.

Success criteria:

- Asking about the current page includes the right URL/title.
- The composer behaves like the main OpenClicky composer.
- Specialist switching changes response style without losing the thread.

### Phase 3: Context extraction and local pages

Deliver:

- Readable page text extraction.
- Selected text handoff.
- Visible viewport screenshot handoff.
- Local file path/dev server detection.
- Context status strip with clear active/unavailable states.

Success criteria:

- OpenClicky can summarize a real article from page text.
- OpenClicky can explain selected text.
- OpenClicky can inspect a local preview with URL/path context.

### Phase 4: Agent task and specialist workflow

Deliver:

- Create Agent Mode tasks from the side panel.
- Show running task state inline.
- Specialist chips can launch scoped task templates.
- Results return to the same browser workspace thread.

Success criteria:

- User can ask “Research this page” and see a running task in-panel.
- User can continue from the result without leaving the workspace.
- Closing/collapsing the panel does not lose task state.

## Open questions

1. Should the workspace use a shared OpenClicky WebKit process pool or a separate ephemeral session by default?
2. Should specialist chips be global presets, user-configurable learned skills, or both?
3. Should the side panel thread be one thread per tab, one thread per window, or manually pinned by the user?
4. Should local file browsing be single-file only at first, or include a folder/project picker?
5. How much browser chrome should be shown when launched from an Agent artifact versus manually opened as a browser workspace?

## First implementation recommendation

Start with a narrow, non-invasive prototype: one new browser workspace window, one WebView, and a clean OpenClicky chat panel with blank transcript, clear action, page context, and basic suggestion chips. Keep ordinary page chat inside the Browser Workspace instance, with a small page-context object containing URL, title, selected text, and optional extracted body text.

## Prototype status - 2026-05-20

Implemented in `cursor-buddy/OpenClickyBrowserWorkspaceWindowManager.swift` and opened from the app menu with Browser Workspace / Command-Option-B after rebuild.

Current prototype covers:

- Native OpenClicky Browser Workspace window shell.
- WebKit canvas for remote URLs, localhost routes, and validated local file paths.
- Welcome/local preview page.
- Basic back, forward, reload, and address loading.
- Docked right OpenClicky chat with a blank default transcript, clear action, page context strip, and basic suggestion chips.
- Collapsible chat side rail and resizable chat side panel, clamped to the spec's 340-540 pt range.
- Functional tab strip: add, activate, close, independent addresses, independent WebViews, and active-tab navigation.
- Split view: drag a tab into the page canvas or use the split rail action to show two tabs side by side.
- Chrome cookie import from selectable local Chrome profiles, with active-site or all-cookie import into OpenClicky's WebKit cookie store.
- Direct page actions from chat for click, press, tap, choose, select, search, type, fill, and enter requests against visible WebKit controls.
- Inline browser plans for prompts such as “search/click the first 4 results and summarize them here”: OpenClicky extracts the query, searches from the Browser Workspace, opens the first result pages as tabs, and posts compact summaries back into the same side chat.
- Page metadata context card with title, URL/path, and web/local state.
- Ordinary page chat, summaries, and key points resolve inline in the Browser Workspace instance.
- Basic page context extraction for readable text, readable text length, and current selection readiness.

Next implementation slice:

1. Replace the prototype chat message handler with the real OpenClicky chat/composer pipeline.
2. Pass active tab URL, title, selected text, readable text, cookie-import state, and split-tab state into the request context.
3. Route only explicitly background/long-running actions into Agent Mode tasks and return results to this workspace thread.

## 2026-05-20 implementation update: chat and persistence

- Browser Workspace chat starts blank, can be cleared, and keeps only basic suggestion chips.
- Browser Workspace chat now handles straightforward page-control requests directly in the active WebKit tab and answers ordinary page prompts inline instead of creating background tasks.
- Browser Workspace chat now has a first inline planning executor for multi-step search-result workflows, keeping “search/open first N/summarize here” inside the browser instance.
- Agent Mode is reserved for prompts that explicitly request background work, ask for subagents/subtasks, or clearly require longer-running coding, file, or deep research work.
- When Agent Mode is needed, the prompt includes title, URL/local route, context status, readable text, selected text, and split-view state.
- Agent history after app restart now persists all visible unarchived sessions, not only interrupted/resumeable ones. Completed sessions should return in the active history after relaunch; archived sessions still remain under Archived.
- Restored sessions are sorted by latest activity so the most recent work appears first, and completed restored sessions do not misleadingly show the resume-after-relaunch action.
