//
//  OpenClickyBrowserAgent.swift
//  OpenClicky
//
//  Playwright-style CUA Browser Agent runner. Uses Anthropic Claude Sonnet with
//  tools to interactively capture, read, and automate the active WKWebView tab.
//

import Foundation
import WebKit
import AppKit

@MainActor
final class OpenClickyBrowserAgentRunner {
    /// Hard cap on autonomous loop iterations. Multi-step browser plans
    /// (open three retailers, compare prices, summarize, etc.) need
    /// substantially more than the original 15 — every navigation +
    /// screenshot + click counts as a turn.
    static let maxAutonomousSteps = 40

    /// Interval at which the loop injects a synthetic plan-progress
    /// reminder so the model doesn't drift away from its committed plan
    /// on long tasks.
    private static let planReminderInterval = 5

    private let apiKey: String
    private let modelName: String
    private weak var browserModel: OpenClickyBrowserWorkspaceModelProtocol?

    /// Set from the workspace via `cancel()` (e.g. `/stop` slash command or
    /// the Cancel button). Polled at the top of each loop iteration; the
    /// runner exits cleanly and posts a status message when set.
    private var cancelRequested = false

    /// Bumped per loop iteration so the UI can surface "Step N/40" status.
    private(set) var currentStep: Int = 0

    /// Allows the chat host to request cancellation between iterations.
    func cancel() {
        cancelRequested = true
    }

    // Tools schema matching Anthropic's Messages API format
    static let tools: [[String: Any]] = [
        [
            "name": "navigate",
            "description": "Navigate the browser tab to a URL or local HTML file path.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "The target URL or local HTML file path to load."
                    ]
                ],
                "required": ["url"]
            ]
        ],
        [
            "name": "screenshot",
            "description": "Capture the current visible webpage viewport as a screenshot to see its visual layout.",
            "input_schema": [
                "type": "object",
                "properties": [:]
            ]
        ],
        [
            "name": "click",
            "description": "Click an interactive element (link, button, input, checkbox, radio, etc.) using a CSS selector, XPath, text matching, or contains matching.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "selector": [
                        "type": "string",
                        "description": "The selector. E.g. CSS ('#submit', 'button.login'), XPath ('xpath=//button'), text match ('text=Login'), or contains ('button:contains(\"Log in\")')."
                    ]
                ],
                "required": ["selector"]
            ]
        ],
        [
            "name": "click_at",
            "description": "Click at specific viewport coordinates on the page if selectors are not working.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "The horizontal coordinate in pixels from the left of the viewport."
                    ],
                    "y": [
                        "type": "number",
                        "description": "The vertical coordinate in pixels from the top of the viewport."
                    ]
                ],
                "required": ["x", "y"]
            ]
        ],
        [
            "name": "type",
            "description": "Type text into an input or editable field.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "selector": [
                        "type": "string",
                        "description": "The selector targeting the input element."
                    ],
                    "text": [
                        "type": "string",
                        "description": "The text to type into the field."
                    ]
                ],
                "required": ["selector", "text"]
            ]
        ],
        [
            "name": "press_key",
            "description": "Press a key on the keyboard, optionally targeting a specific element.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "key": [
                        "type": "string",
                        "description": "The key to press (e.g. 'Enter', 'Tab', 'Escape', 'ArrowDown')."
                    ],
                    "selector": [
                        "type": "string",
                        "description": "Optional selector targeting the element to focus before pressing."
                    ]
                ],
                "required": ["key"]
            ]
        ],
        [
            "name": "scroll",
            "description": "Scroll the page viewport or a scrollable element.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "direction": [
                        "type": "string",
                        "enum": ["up", "down", "left", "right"],
                        "description": "The direction to scroll."
                    ],
                    "amount": [
                        "type": "number",
                        "description": "Optional amount of pixels to scroll. Defaults to half the viewport height."
                    ],
                    "selector": [
                        "type": "string",
                        "description": "Optional selector targeting a specific scrollable element."
                    ]
                ],
                "required": ["direction"]
            ]
        ],
        [
            "name": "wait_for",
            "description": "Wait for a selector to match an element, or for text to be visible on the page.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "selector": [
                        "type": "string",
                        "description": "Optional selector to wait for."
                    ],
                    "text": [
                        "type": "string",
                        "description": "Optional text to wait for."
                    ],
                    "timeoutMs": [
                        "type": "number",
                        "description": "Optional max wait duration in milliseconds. Default 5000."
                    ]
                ]
            ]
        ],
        [
            "name": "get_content",
            "description": "Get the current page URL, title, selected text, and extracted readable text content.",
            "input_schema": [
                "type": "object",
                "properties": [:]
            ]
        ],
        [
            "name": "evaluate",
            "description": "Execute arbitrary Javascript in the page context and return the serialized result.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "script": [
                        "type": "string",
                        "description": "The Javascript code to execute."
                    ]
                ],
                "required": ["script"]
            ]
        ],
        [
            "name": "done",
            "description": "Signal that the user's goal has been fully achieved. Call this once with a concise natural-language summary of what was accomplished and any final answer the user asked for. After calling `done` you MUST stop emitting tool calls.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "summary": [
                        "type": "string",
                        "description": "A 1-3 sentence natural-language summary of the result for the user. Include any direct answer they asked for."
                    ]
                ],
                "required": ["summary"]
            ]
        ]
    ]

    init(apiKey: String, modelName: String, browserModel: OpenClickyBrowserWorkspaceModelProtocol) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName
        self.browserModel = browserModel
    }

    /// Conversation history for follow-up turns — every prior user prompt and
    /// the assistant's final reply, in chronological order. The runner uses
    /// this to seed the next run so the user can say "now do X" and the agent
    /// remembers the prior plan and what was accomplished.
    struct PriorTurn: Sendable {
        let userPrompt: String
        let assistantSummary: String
        init(userPrompt: String, assistantSummary: String) {
            self.userPrompt = userPrompt
            self.assistantSummary = assistantSummary
        }
    }

    /// Plan-first, step-disciplined CUA system prompt shared by both code paths.
    private static let systemPrompt = """
    You are OpenClicky's Browser CUA (Computer Use Agent). You drive the active
    tab of OpenClicky's built-in browser to achieve the user's goal. You can
    see the page via screenshots, read text via `get_content`, and act via
    `click`, `type`, `press_key`, `scroll`, `wait_for`, `navigate`, `click_at`,
    and `evaluate`.

    PLANNING DISCIPLINE
    1. On your VERY FIRST assistant turn, before calling any tool, emit a short
       numbered plan (1 line per step, 2-8 steps total). Wrap it like:
         Plan:
         1. ...
         2. ...
       Then immediately start executing step 1 with a tool call in the same turn.
    2. Before each subsequent tool call, briefly state which plan step you are
       executing (e.g. "Step 3: typing the search query").
    3. After tool results come back, decide: continue, revise the plan, or
       finish. If you revise, emit "Plan update:" and the new numbered list.
    4. Prefer selector-based tools (`click`, `type`) with CSS / `text=...` /
       `contains(...)` / `xpath=...`. Use `click_at` only when selectors fail.
    5. After navigation or any action that changes the view, call `screenshot`
       to re-orient before acting.
    6. When the goal is fully achieved, call the `done` tool exactly once with
       a concise summary. Do not emit further tool calls after `done`.
    7. If you hit a hard block (login wall, captcha, missing data), call `done`
       with an honest summary explaining the block.

    SAFETY
    - Never run `evaluate` scripts that exfiltrate cookies, localStorage, or
      tokens unless the user explicitly asks for that.
    - Do not navigate to off-task destinations.
    """

    /// Entry point to execute the CUA Agent loop.
    /// - Parameters:
    ///   - prompt: the new user goal for this turn.
    ///   - priorTurns: prior user/assistant turns for conversational memory.
    func run(prompt: String, priorTurns: [PriorTurn] = []) async {
        guard let model = browserModel else { return }

        cancelRequested = false
        currentStep = 0

        let hasAPIKey = !apiKey.isEmpty
        let useSDK = await MainActor.run {
            model.hasAgentSDK()
        }

        // Prefer the direct HTTP path whenever an Anthropic API key is
        // configured — it speaks real `tool_use` blocks and feeds screenshots
        // back as `tool_result` images. The SDK fallback only re-parses JSON
        // out of free-text and is much more fragile.
        if !hasAPIKey && useSDK {
            await runWithAgentSDK(prompt: prompt, priorTurns: priorTurns)
            return
        }
        if !hasAPIKey {
            appendAgentMessage(text: "I need an Anthropic API key (or the Claude Agent SDK) to drive the browser. Add one in Settings and try again.")
            return
        }

        var messages: [[String: Any]] = []

        // Seed conversational memory. Each prior turn collapses to a short
        // user/assistant pair so the model knows what was previously asked
        // and accomplished without replaying every screenshot.
        for turn in priorTurns {
            messages.append([
                "role": "user",
                "content": [["type": "text", "text": "Earlier goal: \(turn.userPrompt)"]]
            ])
            messages.append([
                "role": "assistant",
                "content": [["type": "text", "text": "Earlier outcome: \(turn.assistantSummary)"]]
            ])
        }

        // Build the initial user turn with current page metadata + a fresh
        // screenshot so the model is grounded before planning.
        var userContentBlocks: [[String: Any]] = []
        var pageMeta = "No active page loaded yet."
        if let tabDetails = await getTabContentDetails() {
            pageMeta = "Current Tab URL: \(tabDetails["url"] as? String ?? "none")\n" +
                       "Page Title: \(tabDetails["title"] as? String ?? "Untitled")"
            if let selection = tabDetails["selection"] as? String, !selection.isEmpty {
                pageMeta += "\nSelected text: \(selection)"
            }
        }
        userContentBlocks.append(["type": "text", "text": "Page metadata:\n\(pageMeta)"])
        if let screenshotData = await captureTabScreenshot() {
            let mediaType = detectImageMediaType(for: screenshotData)
            userContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": screenshotData.base64EncodedString()
                ]
            ])
        }
        userContentBlocks.append(["type": "text", "text": "Goal: \(prompt)"])
        messages.append(["role": "user", "content": userContentBlocks])

        let maxLoops = Self.maxAutonomousSteps
        var loopCount = 0
        var lastAssistantText = ""
        var explicitlyDone = false
        var doneSummary: String?

        while loopCount < maxLoops {
            loopCount += 1
            currentStep = loopCount

            if cancelRequested {
                postAgentStatus(text: "Stopped at step \(loopCount). The browser plan was cancelled.")
                break
            }

            postAgentStatus(text: "Step \(loopCount)/\(maxLoops): thinking…")

            // Inject a synthetic plan check-in periodically so the model
            // stays anchored to its original plan on long runs.
            if loopCount > 1 && (loopCount - 1) % Self.planReminderInterval == 0 {
                messages.append([
                    "role": "user",
                    "content": [[
                        "type": "text",
                        "text": "Plan check-in: we are on step \(loopCount) of up to \(maxLoops). Restate the remaining plan items, then continue. If the goal is achieved, call `done`."
                    ]]
                ])
            }

            do {
                let response = try await callClaudeAPI(systemPrompt: Self.systemPrompt, messages: messages)

                guard let content = response["content"] as? [[String: Any]] else {
                    appendAgentMessage(text: "I couldn't complete that in the browser because the model response was invalid.")
                    break
                }

                messages.append(["role": "assistant", "content": content])

                var textResponse = ""
                var toolCalls: [[String: Any]] = []
                for block in content {
                    let type = block["type"] as? String ?? ""
                    if type == "text" {
                        textResponse += block["text"] as? String ?? ""
                    } else if type == "tool_use" {
                        toolCalls.append(block)
                    }
                }

                if !textResponse.isEmpty {
                    appendAgentMessage(text: textResponse)
                    lastAssistantText = textResponse
                }

                // Handle `done` tool specially before executing anything else
                // so the run terminates cleanly even if the model also emitted
                // parallel tool calls in the same turn.
                if let doneCall = toolCalls.first(where: { ($0["name"] as? String) == "done" }) {
                    let input = doneCall["input"] as? [String: Any] ?? [:]
                    doneSummary = (input["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    explicitlyDone = true

                    // Acknowledge the done call with a tool_result so the
                    // conversation history stays valid for follow-ups.
                    if let doneID = doneCall["id"] as? String {
                        let resultBlock: [String: Any] = [
                            "type": "tool_result",
                            "tool_use_id": doneID,
                            "content": "Acknowledged. Task complete."
                        ]
                        messages.append(["role": "user", "content": [resultBlock]])
                    }
                    break
                }

                if toolCalls.isEmpty {
                    // No tool calls and no `done` — treat as a soft finish.
                    break
                }

                if cancelRequested {
                    postAgentStatus(text: "Stopped at step \(loopCount). The browser plan was cancelled.")
                    break
                }

                var toolResultBlocks: [[String: Any]] = []
                for toolCall in toolCalls {
                    guard let toolUseID = toolCall["id"] as? String,
                          let toolName = toolCall["name"] as? String,
                          let input = toolCall["input"] as? [String: Any] else {
                        continue
                    }

                    postAgentStatus(text: "Step \(loopCount)/\(maxLoops): \(toolName)")
                    let toolResult = await executeTool(name: toolName, input: input)

                    var resultBlock: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolUseID
                    ]
                    if toolResult.isError {
                        resultBlock["is_error"] = true
                    }
                    if let image = toolResult.imageData {
                        let mediaType = detectImageMediaType(for: image)
                        resultBlock["content"] = [
                            ["type": "text", "text": toolResult.summary],
                            [
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": mediaType,
                                    "data": image.base64EncodedString()
                                ]
                            ]
                        ]
                    } else {
                        resultBlock["content"] = toolResult.summary
                    }
                    toolResultBlocks.append(resultBlock)
                }

                messages.append(["role": "user", "content": toolResultBlocks])
            } catch {
                appendAgentMessage(text: "I couldn't complete that in the browser. Check the selected browser model/API setup and try again. (\(error.localizedDescription))")
                break
            }
        }

        if explicitlyDone, let summary = doneSummary, !summary.isEmpty {
            appendAgentMessage(text: summary)
            recordRunOutcome(prompt: prompt, summary: summary)
        } else if cancelRequested {
            recordRunOutcome(prompt: prompt, summary: "Cancelled by user at step \(loopCount).")
        } else if loopCount >= maxLoops {
            appendAgentMessage(text: "I hit the \(maxLoops)-step limit before finishing. Send a follow-up if you want me to keep going.")
            recordRunOutcome(prompt: prompt, summary: "Stopped at the \(maxLoops)-step limit.")
        } else if !lastAssistantText.isEmpty {
            recordRunOutcome(prompt: prompt, summary: lastAssistantText)
        }

        postAgentStatus(text: "")
    }

    private struct ToolResult {
        let success: Bool
        let summary: String
        let isError: Bool
        let imageData: Data?
        
        static func success(summary: String, imageData: Data? = nil) -> ToolResult {
            return ToolResult(success: true, summary: summary, isError: false, imageData: imageData)
        }
        
        static func failure(summary: String) -> ToolResult {
            return ToolResult(success: false, summary: summary, isError: true, imageData: nil)
        }
    }

    // Router for executing tools on active tab
    private func executeTool(name: String, input: [String: Any]) async -> ToolResult {
        switch name {
        case "navigate":
            guard let url = input["url"] as? String else {
                return .failure(summary: "Missing required parameter: url")
            }
            return await executeNavigate(url: url)
            
        case "screenshot":
            if let screenshotData = await captureTabScreenshot() {
                return .success(summary: "Captured page layout screenshot.", imageData: screenshotData)
            } else {
                return .failure(summary: "Failed to capture page screenshot.")
            }
            
        case "click":
            guard let selector = input["selector"] as? String else {
                return .failure(summary: "Missing required parameter: selector")
            }
            return await runInjectedJSAction(kind: "click", selector: selector, value: nil)
            
        case "click_at":
            guard let x = input["x"] as? Double, let y = input["y"] as? Double else {
                return .failure(summary: "Missing required parameter: x, y")
            }
            return await runInjectedJSAction(kind: "click_at", selector: "\(x)", value: "\(y)")
            
        case "type":
            guard let selector = input["selector"] as? String,
                  let text = input["text"] as? String else {
                return .failure(summary: "Missing required parameter: selector, text")
            }
            return await runInjectedJSAction(kind: "type", selector: selector, value: text)
            
        case "press_key":
            guard let key = input["key"] as? String else {
                return .failure(summary: "Missing required parameter: key")
            }
            let selector = input["selector"] as? String
            return await runInjectedJSAction(kind: "press_key", selector: selector, value: key)
            
        case "scroll":
            guard let direction = input["direction"] as? String else {
                return .failure(summary: "Missing required parameter: direction")
            }
            let amount = input["amount"] as? Double
            let selector = input["selector"] as? String
            let val = amount != nil ? "\(amount!)" : direction
            return await runInjectedJSAction(kind: "scroll", selector: selector, value: val)
            
        case "wait_for":
            let selector = input["selector"] as? String
            let text = input["text"] as? String
            let timeoutMs = input["timeoutMs"] as? Double ?? 5000.0
            return await executeWaitFor(selector: selector, text: text, timeoutMs: timeoutMs)
            
        case "get_content":
            let result = await runInjectedJSAction(kind: "get_content", selector: nil, value: nil)
            return result
            
        case "evaluate":
            guard let script = input["script"] as? String else {
                return .failure(summary: "Missing required parameter: script")
            }
            return await executeEvaluate(script: script)
            
        default:
            return .failure(summary: "Unknown tool: \(name)")
        }
    }

    // MARK: - Specific Tool Handlers
    
    private func executeNavigate(url: String) async -> ToolResult {
        let lower = url.lowercased()
        var targetURL: URL?
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") || lower.hasPrefix("open-clicky://") {
            targetURL = URL(string: url)
        } else if url.contains(".") && !url.contains(" ") {
            targetURL = URL(string: "https://\(url)")
        }
        
        guard let targetURL = targetURL else {
            return .failure(summary: "Failed: Invalid URL format '\(url)'.")
        }
        
        await MainActor.run {
            _ = self.browserModel?.loadAddress(targetURL.absoluteString)
        }
        
        // Wait a second for navigation to initiate
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return .success(summary: "Successfully initiated navigation to \(targetURL.absoluteString).")
    }

    private func executeWaitFor(selector: String?, text: String?, timeoutMs: Double) async -> ToolResult {
        guard selector != nil || text != nil else {
            return .failure(summary: "Failed: Must specify either selector or text to wait for.")
        }
        
        let start = Date()
        let limit = timeoutMs / 1000.0
        let step = 0.25 // check every 250ms
        
        while Date().timeIntervalSince(start) < limit {
            if let sel = selector {
                let js = "document.querySelector(\(escapeJSString(sel))) !== null"
                if let exists = await evaluateRawJS(js) as? Bool, exists {
                    return .success(summary: "Element matching '\(sel)' appeared on the page.")
                }
            } else if let txt = text {
                let js = "document.body.innerText.toLowerCase().includes(\(escapeJSString(txt.lowercased())))"
                if let exists = await evaluateRawJS(js) as? Bool, exists {
                    return .success(summary: "Text '\(txt)' appeared on the page.")
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
        
        let desc = selector != nil ? "element matching '\(selector!)'" : "text '\(text!)'"
        return .failure(summary: "Timed out waiting for \(desc) to appear after \(timeoutMs)ms.")
    }

    private func executeEvaluate(script: String) async -> ToolResult {
        do {
            if let result = try await evaluateRawJSWithThrowing(script) {
                return .success(summary: "Script evaluated. Result: \(result)")
            } else {
                return .success(summary: "Script evaluated successfully (no return value).")
            }
        } catch {
            return .failure(summary: "Javascript execution failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Injected Action Engine
    
    private func runInjectedJSAction(kind: String, selector: String?, value: String?) async -> ToolResult {
        let script = CuaInjectedScriptGenerator.generateScript(actionKind: kind, selector: selector, value: value)
        
        do {
            let result = try await evaluateRawJSWithThrowing(script)
            guard let dict = result as? [String: Any] else {
                return .failure(summary: "Invalid response from page actions script.")
            }
            
            let success = dict["success"] as? Bool ?? false
            let summary = dict["summary"] as? String ?? dict["error"] as? String ?? "Done."
            
            if success {
                // If it is get_content, summarize the content
                if kind == "get_content" {
                    let pageTitle = dict["title"] as? String ?? "Untitled"
                    let pageURL = dict["url"] as? String ?? "none"
                    return .success(summary: "Extracted content for tab: '\(pageTitle)' (\(pageURL)).")
                }
                return .success(summary: summary)
            } else {
                return .failure(summary: "Failed: \(summary)")
            }
        } catch {
            return .failure(summary: "Execution error on webpage: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Bridges
    
    private func getTabContentDetails() async -> [String: Any]? {
        let script = CuaInjectedScriptGenerator.generateScript(actionKind: "get_content", selector: nil, value: nil)
        if let result = await evaluateRawJS(script) as? [String: Any] {
            return result
        }
        return nil
    }

    private func evaluateRawJS(_ js: String) async -> Any? {
        do {
            return try await evaluateRawJSWithThrowing(js)
        } catch {
            return nil
        }
    }

    private func evaluateRawJSWithThrowing(_ js: String) async throws -> Any? {
        guard let webView = await getActiveWebView() else {
            throw NSError(domain: "BrowserAgent", code: -101, userInfo: [NSLocalizedDescriptionKey: "No active WKWebView tab loaded."])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func getActiveWebView() async -> WKWebView? {
        await MainActor.run {
            self.browserModel?.getActiveWebView()
        }
    }

    private func captureTabScreenshot() async -> Data? {
        await self.browserModel?.captureActiveTabScreenshot()
    }

    // MARK: - UI Message Dispatchers

    private func appendAgentMessage(text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        Task { @MainActor in
            self.browserModel?.appendAgentMessage(text: cleaned)
        }
    }

    /// Posts a transient "what the agent is doing right now" line. The
    /// workspace surfaces this as a small status row above the composer so
    /// the user can see progress between text turns and can cancel.
    private func postAgentStatus(text: String) {
        Task { @MainActor in
            self.browserModel?.setBrowserAgentStatus(text: text)
        }
    }

    /// Stores the outcome of this run so subsequent prompts in the same
    /// workspace conversation can be threaded together (the "talk like a
    /// regular OpenClicky agent" path).
    private func recordRunOutcome(prompt: String, summary: String) {
        let cleanedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSummary.isEmpty else { return }
        Task { @MainActor in
            self.browserModel?.recordBrowserAgentOutcome(prompt: prompt, summary: cleanedSummary)
        }
    }

    // MARK: - Networking
    
    private func callClaudeAPI(systemPrompt: String, messages: [[String: Any]]) async throws -> [String: Any] {
        let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": 4000,
            "system": systemPrompt,
            "messages": messages,
            "tools": Self.tools
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "BrowserAgent", code: -102, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown HTTP status \(httpResponse.statusCode)"
            throw NSError(domain: "BrowserAgent", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Claude API Error: \(errorText)"])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "BrowserAgent", code: -103, userInfo: [NSLocalizedDescriptionKey: "Failed to parse API response as JSON."])
        }
        
        return json
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    private func escapeJSString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }

    private func runWithAgentSDK(prompt: String, priorTurns: [PriorTurn] = []) async {
        guard let model = browserModel else { return }

        // Seed the SDK conversation with prior workspace turns so the user can
        // ask follow-ups even on this fallback path.
        var sdkHistory: [(userPlaceholder: String, assistantResponse: String)] = priorTurns.map {
            ("Earlier goal: \($0.userPrompt)", "Earlier outcome: \($0.assistantSummary)")
        }

        var loopCount = 0
        let maxLoops = Self.maxAutonomousSteps

        var pageMeta = "No active page loaded yet."
        let tabContent = await getTabContentDetails()
        if let tabDetails = tabContent {
            pageMeta = "Current Tab URL: \(tabDetails["url"] as? String ?? "none")\n" +
                       "Page Title: \(tabDetails["title"] as? String ?? "Untitled")"
            if let selection = tabDetails["selection"] as? String, !selection.isEmpty {
                pageMeta += "\nSelected text: \(selection)"
            }
        }

        let initialUserPrompt = "Goal: \(prompt)\n\nPage metadata:\n\(pageMeta)"
        var currentImages: [(data: Data, label: String)] = []
        if let screenshotData = await captureTabScreenshot() {
            currentImages.append((screenshotData, "current_screen"))
        }

        // Reuse the shared plan-first system prompt, but augment it with the
        // SDK's text-only tool-call protocol because this path can't return
        // `tool_use` blocks natively.
        let sdkSystemPrompt = Self.systemPrompt + """


        SDK CALL PROTOCOL
        You are inside the Browser Workspace runner. Do not use host web
        search, terminal commands, local file tools, or any external browser.
        The only actions that count are JSON tool calls from the list above,
        executed by OpenClicky against the active WKWebView tab.
        To execute a tool, reply with ONLY a JSON object of the form:
        { "tool": "tool_name", "input": { ... } }
        No prose, no markdown — JSON object only when you intend to call a tool.
        When you finish, emit one final JSON object { "tool": "done", "input": { "summary": "..." } }.
        """

        var nextUserPrompt = initialUserPrompt
        var lastAssistantText = ""
        var explicitlyDone = false
        var doneSummary: String?

        while loopCount < maxLoops {
            loopCount += 1
            currentStep = loopCount

            if cancelRequested {
                postAgentStatus(text: "Stopped at step \(loopCount). The browser plan was cancelled.")
                break
            }

            postAgentStatus(text: "Step \(loopCount)/\(maxLoops): thinking…")

            // Periodic plan reminder on the SDK path too.
            if loopCount > 1 && (loopCount - 1) % Self.planReminderInterval == 0 {
                nextUserPrompt += "\n\nPlan check-in: we're on step \(loopCount) of \(maxLoops). Restate remaining steps, then continue. If done, emit the done tool."
            }

            do {
                let responseText = try await model.analyzeImageWithAgentSDK(
                    images: currentImages,
                    systemPrompt: sdkSystemPrompt,
                    conversationHistory: sdkHistory,
                    userPrompt: nextUserPrompt,
                    onTextChunk: { _ in }
                )

                sdkHistory.append((nextUserPrompt, responseText))
                lastAssistantText = responseText

                if let toolCall = parseJSONToolCall(from: responseText) {
                    if toolCall.name == "done" {
                        explicitlyDone = true
                        doneSummary = (toolCall.input["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }

                    postAgentStatus(text: "Step \(loopCount)/\(maxLoops): \(toolCall.name)")
                    let toolResult = await executeTool(name: toolCall.name, input: toolCall.input)

                    currentImages.removeAll()
                    if let screenshotData = await captureTabScreenshot() {
                        currentImages.append((screenshotData, "current_screen"))
                    }
                    nextUserPrompt = "Tool '\(toolCall.name)' executed with result: \(toolResult.summary)"
                } else {
                    // Plain text reply — treat as soft completion.
                    appendAgentMessage(text: responseText)
                    break
                }
            } catch {
                appendAgentMessage(text: "I couldn't complete that in the browser. Check the selected browser model/API setup and try again. (\(error.localizedDescription))")
                break
            }
        }

        if explicitlyDone, let summary = doneSummary, !summary.isEmpty {
            appendAgentMessage(text: summary)
            recordRunOutcome(prompt: prompt, summary: summary)
        } else if cancelRequested {
            recordRunOutcome(prompt: prompt, summary: "Cancelled by user at step \(loopCount).")
        } else if loopCount >= maxLoops {
            appendAgentMessage(text: "I hit the \(maxLoops)-step limit before finishing. Send a follow-up if you want me to keep going.")
            recordRunOutcome(prompt: prompt, summary: "Stopped at the \(maxLoops)-step limit.")
        } else if !lastAssistantText.isEmpty {
            recordRunOutcome(prompt: prompt, summary: lastAssistantText)
        }

        postAgentStatus(text: "")
        
        if loopCount >= maxLoops {
            appendAgentMessage(text: "I couldn't finish that browser action within the step limit.")
        }
    }

    private func parseJSONToolCall(from text: String) -> (name: String, input: [String: Any])? {
        guard let start = text.range(of: "{"),
              let end = text.range(of: "}", options: .backwards),
              start.upperBound <= end.lowerBound else {
            return nil
        }
        
        let jsonStr = String(text[start.lowerBound...end.lowerBound])
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = dict["tool"] as? String,
              let input = dict["input"] as? [String: Any] else {
            return nil
        }
        
        return (name, input)
    }
}

// MARK: - Script Generator

private enum CuaInjectedScriptGenerator {
    static func generateScript(actionKind: String, selector: String?, value: String?) -> String {
        let selectorJSON = selector != nil ? escapeJSString(selector!) : "null"
        let valueJSON = value != nil ? escapeJSString(value!) : "null"
        
        return """
        (() => {
          const specRaw = \(selectorJSON);
          const actionKind = "\(actionKind)";
          const value = \(valueJSON);
          
          const stripQuotes = (val) => {
            const t = val.trim();
            if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
              return t.slice(1, -1);
            }
            return t;
          };
          
          const parseSelectorSpec = (raw) => {
            const trimmed = String(raw || '').trim();
            const lower = trimmed.toLowerCase();
            if (lower.startsWith('css=')) {
              return { kind: 'css', selector: trimmed.slice(4).trim() };
            }
            if (lower.startsWith('xpath=')) {
              return { kind: 'xpath', xpath: trimmed.slice(6).trim() };
            }
            const textMatch = /^text\\s*=\\s*(.+)$/i.exec(trimmed);
            if (textMatch) {
              return { kind: 'text', text: stripQuotes(textMatch[1]).trim() };
            }
            const containsDotQuoted = /^([a-zA-Z][\\\\w-]*)\\s*\\.\\s*contains\\s*\\(\\s*(['"])([\\\\s\\\\S]*?)\\2\\s*\\)\\s*$/.exec(trimmed);
            if (containsDotQuoted) {
              return { kind: 'contains', base: containsDotQuoted[1], text: containsDotQuoted[3].trim() };
            }
            const containsDotBare = /^([a-zA-Z][\\\\w-]*)\\s*\\.\\s*contains\\s*\\(\\s*([\\\\s\\\\S]*?)\\s*\\)\\s*$/.exec(trimmed);
            if (containsDotBare) {
              return { kind: 'contains', base: containsDotBare[1], text: String(containsDotBare[2] || '').trim() };
            }
            const pseudoContainsQuoted = /^(.+?):\\s*contains\\s*\\(\\s*(['"])([\\\\s\\\\S]*?)\\2\\s*\\)\\s*$/.exec(trimmed);
            if (pseudoContainsQuoted) {
              return { kind: 'contains', base: pseudoContainsQuoted[1].trim(), text: pseudoContainsQuoted[3].trim() };
            }
            const pseudoContainsBare = /^(.+?):\\s*contains\\s*\\(\\s*([\\\\s\\\\S]*?)\\s*\\)\\s*$/.exec(trimmed);
            if (pseudoContainsBare) {
              return { kind: 'contains', base: pseudoContainsBare[1].trim(), text: String(pseudoContainsBare[2] || '').trim() };
            }
            const pseudoHasTextQuoted = /^(.+?):\\s*has-text\\s*\\(\\s*(['"])([\\\\s\\\\S]*?)\\2\\s*\\)\\s*$/.exec(trimmed);
            if (pseudoHasTextQuoted) {
              return { kind: 'contains', base: pseudoHasTextQuoted[1].trim(), text: pseudoHasTextQuoted[3].trim() };
            }
            const pseudoHasTextBare = /^(.+?):\\s*has-text\\s*\\(\\s*([\\\\s\\\\S]*?)\\s*\\)\\s*$/.exec(trimmed);
            if (pseudoHasTextBare) {
              return { kind: 'contains', base: pseudoHasTextBare[1].trim(), text: String(pseudoHasTextBare[2] || '').trim() };
            }
            return { kind: 'css', selector: trimmed };
          };

          const isVisible = (el) => {
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) return false;
            const style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (parseFloat(style.opacity || '1') === 0) return false;
            return true;
          };

          const deepQuerySelectorAll = (css, maxNodes = 25000) => {
            const out = [];
            let parsedOk = true;
            try {
              document.querySelector(css);
            } catch {
              parsedOk = false;
            }
            if (!parsedOk) return out;

            const stack = [document];
            let visited = 0;
            while (stack.length && visited < maxNodes) {
              const node = stack.pop();
              if (node instanceof Element) {
                visited += 1;
                try {
                  if (node.matches(css)) out.push(node);
                } catch {}
                const sr = node.shadowRoot;
                if (sr) stack.push(sr);
                for (const child of Array.from(node.children)) stack.push(child);
              } else {
                const children = node instanceof Document ? [node.documentElement] : Array.from(node.children);
                for (const child of children) if (child) stack.push(child);
              }
            }
            return out;
          };

          const findByText = (text, baseSelector = '', allowDeepSearch = true) => {
            const wanted = String(text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            if (!wanted) return { el: null, candidates: 0 };
            
            let preferred = [];
            if (baseSelector) {
              try {
                preferred = Array.from(document.querySelectorAll(baseSelector));
              } catch (e) {
                if (allowDeepSearch) preferred = deepQuerySelectorAll(baseSelector);
              }
            } else {
              preferred = Array.from(document.querySelectorAll('a, button, input, [role="button"], [role="link"], summary'));
            }
            
            const pool = preferred.length > 0 ? preferred : Array.from(document.querySelectorAll('body *'));
            let best = null;
            let bestScore = -1;
            let seen = 0;
            
            for (const el of pool) {
              if (!(el instanceof HTMLElement)) continue;
              if (!isVisible(el)) continue;
              const txt = String(el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
              if (!txt) continue;
              if (!txt.includes(wanted)) continue;
              seen += 1;
              
              const tag = el.tagName.toLowerCase();
              let score = 1;
              if (tag === 'button') score += 4;
              if (tag === 'a') score += 3;
              if (tag === 'input') score += 2;
              if (el.getAttribute('role') === 'button') score += 2;
              if (score > bestScore) {
                best = el;
                bestScore = score;
              }
            }
            return { el: best, candidates: seen };
          };

          const resolveElement = (spec, allowDeepSearch) => {
            if (!spec) return { el: null, strategy: 'none', candidates: 0, error: 'Missing selector.' };
            
            if (spec.kind === 'xpath') {
              const expr = String(spec.xpath || '').trim();
              try {
                const res = document.evaluate(expr, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                const node = res.singleNodeValue;
                if (node && node instanceof HTMLElement) return { el: node, strategy: 'xpath', candidates: 1 };
                return { el: null, strategy: 'xpath', candidates: 0, error: 'Element not found.' };
              } catch (e) {
                return { el: null, strategy: 'xpath', candidates: 0, error: 'Invalid XPath.', hint: e.message };
              }
            }
            
            if (spec.kind === 'text') {
              const { el, candidates } = findByText(spec.text, '', allowDeepSearch);
              return el ? { el, strategy: 'text', candidates } : { el: null, strategy: 'text', candidates, error: 'Element not found.' };
            }
            
            if (spec.kind === 'contains') {
              const { el, candidates } = findByText(spec.text, spec.base, allowDeepSearch);
              return el ? { el, strategy: 'contains', candidates } : { el: null, strategy: 'contains', candidates, error: 'Element not found.' };
            }
            
            const css = String(spec.selector || '').trim();
            try {
              const matches = Array.from(document.querySelectorAll(css));
              const vis = matches.filter(isVisible);
              const el = vis[0] || matches[0] || null;
              if (el) return { el, strategy: 'css', candidates: matches.length };
            } catch (e) {
              return { el: null, strategy: 'css', candidates: 0, error: 'Invalid selector.', hint: e.message };
            }
            
            if (allowDeepSearch) {
              const deep = deepQuerySelectorAll(css);
              const deepVis = deep.filter(isVisible);
              const el = deepVis[0] || deep[0] || null;
              if (el) return { el, strategy: 'css(deep)', candidates: deep.length };
            }
            
            return { el: null, strategy: 'css', candidates: 0, error: 'Element not found.' };
          };

          const doClick = (el) => {
            try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch(e){}
            try { el.focus({ preventScroll: true }); } catch(e){}
            
            const rect = el.getBoundingClientRect();
            const cx = Math.max(1, Math.min(window.innerWidth - 2, rect.left + rect.width / 2));
            const cy = Math.max(1, Math.min(window.innerHeight - 2, rect.top + rect.height / 2));
            const top = document.elementFromPoint(cx, cy);
            const target = top && (top === el || el.contains(top)) ? top : el;
            
            const fire = (type, cls) => {
              try {
                const ev = new cls(type, { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy, button: 0 });
                target.dispatchEvent(ev);
              } catch(e){}
            };
            
            fire('pointerover', window.PointerEvent || MouseEvent);
            fire('mouseover', MouseEvent);
            fire('pointerdown', window.PointerEvent || MouseEvent);
            fire('mousedown', MouseEvent);
            fire('pointerup', window.PointerEvent || MouseEvent);
            fire('mouseup', MouseEvent);
            fire('click', MouseEvent);
            try { target.click(); } catch(e){}
            return { success: true, clickedTagName: target.tagName, x: cx, y: cy };
          };

          const doType = (el, text) => {
            try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch(e){}
            try { el.focus({ preventScroll: true }); } catch(e){}
            
            const resolveEditable = (candidate) => {
              if (!candidate) return null;
              if (candidate instanceof HTMLInputElement || candidate instanceof HTMLTextAreaElement || candidate.isContentEditable) {
                return candidate;
              }
              return candidate.querySelector('textarea, input, [contenteditable="true"], [contenteditable=""], [role="textbox"]');
            };
            
            const editable = resolveEditable(el);
            if (!editable) return { success: false, error: 'Target element is not inputable/editable.' };
            
            if (editable instanceof HTMLInputElement || editable instanceof HTMLTextAreaElement) {
              if (editable.type === 'checkbox' || editable.type === 'radio') {
                return { success: false, error: 'Element is a checkbox/radio, use click instead.' };
              }
              
              if (typeof editable.select === 'function') {
                try { editable.select(); } catch(e){}
              }
              
              const setVal = (tgt, val) => {
                const proto = Object.getPrototypeOf(tgt);
                const desc = Object.getOwnPropertyDescriptor(proto, 'value');
                if (desc && desc.set) {
                  desc.set.call(tgt, val);
                } else {
                  tgt.value = val;
                }
              };
              
              setVal(editable, text);
              
              const dispatch = (type, cls, opts) => {
                try { editable.dispatchEvent(new cls(type, opts)); } catch(e){}
              };
              
              dispatch('input', InputEvent, { bubbles: true, inputType: 'insertText', data: text });
              dispatch('change', Event, { bubbles: true });
              return { success: true };
            }
            
            if (editable.isContentEditable) {
              const selection = window.getSelection();
              if (selection) {
                selection.removeAllRanges();
                const range = document.createRange();
                range.selectNodeContents(editable);
                selection.addRange(range);
              }
              document.execCommand?.('insertText', false, text);
              if (editable.textContent !== text) {
                editable.textContent = text;
              }
              editable.dispatchEvent(new Event('input', { bubbles: true }));
              editable.dispatchEvent(new Event('change', { bubbles: true }));
              return { success: true };
            }
            return { success: false, error: 'Target is not editable.' };
          };

          try {
            if (actionKind === 'get_content') {
              const visibleText = document.body ? document.body.innerText : '';
              const selection = window.getSelection() ? window.getSelection().toString() : '';
              return {
                success: true,
                url: window.location.href,
                title: document.title,
                selection: selection,
                readableText: visibleText.slice(0, 10000)
              };
            }
            
            if (actionKind === 'scroll') {
              let scrollTarget = window;
              if (specRaw) {
                const spec = parseSelectorSpec(specRaw);
                const res = resolveElement(spec, true);
                if (res.el) scrollTarget = res.el;
              }
              
              const amt = value ? parseFloat(value) : window.innerHeight / 2;
              let dx = 0, dy = 0;
              const dir = String(value || 'down').toLowerCase();
              if (dir === 'up') dy = -amt;
              else if (dir === 'down') dy = amt;
              else if (dir === 'left') dx = -amt;
              else if (dir === 'right') dx = amt;
              
              if (scrollTarget === window) {
                window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
              } else {
                scrollTarget.scrollLeft += dx;
                scrollTarget.scrollTop += dy;
              }
              return { success: true, summary: `Scrolled ${dir} by ${amt}px.` };
            }
            
            if (actionKind === 'press_key') {
              let target = document.activeElement || document.body;
              if (specRaw) {
                const spec = parseSelectorSpec(specRaw);
                const res = resolveElement(spec, true);
                if (res.el) target = res.el;
              }
              const key = String(value || 'Enter');
              const fireKey = (type) => {
                const ev = new KeyboardEvent(type, { key: key, code: key, bubbles: true, cancelable: true });
                target.dispatchEvent(ev);
              };
              fireKey('keydown');
              fireKey('keypress');
              fireKey('keyup');
              return { success: true, summary: `Pressed key '${key}' on target.` };
            }
            
            if (actionKind === 'click_at') {
              const cx = parseFloat(specRaw);
              const cy = parseFloat(value);
              const target = document.elementFromPoint(cx, cy) || document.body;
              const fire = (type, cls) => {
                try {
                  const ev = new cls(type, { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy, button: 0 });
                  target.dispatchEvent(ev);
                } catch(e){}
              };
              fire('pointerover', window.PointerEvent || MouseEvent);
              fire('mouseover', MouseEvent);
              fire('pointerdown', window.PointerEvent || MouseEvent);
              fire('mousedown', MouseEvent);
              fire('pointerup', window.PointerEvent || MouseEvent);
              fire('mouseup', MouseEvent);
              fire('click', MouseEvent);
              try { target.click(); } catch(e){}
              return { success: true, summary: `Clicked coordinate (${cx}, ${cy}) targeting tag ${target.tagName}.` };
            }

            const spec = parseSelectorSpec(specRaw);
            const res = resolveElement(spec, true);
            if (!res.el) {
              return { success: false, error: res.error || 'Element not found.', strategy: res.strategy, candidates: res.candidates };
            }
            
            if (actionKind === 'click') {
              const clickRes = doClick(res.el);
              const name = res.el.innerText || res.el.value || res.el.getAttribute('aria-label') || res.el.id || res.el.tagName;
              return { ...clickRes, summary: `Successfully clicked element: "${name.substring(0, 30).trim()}"` };
            }
            
            if (actionKind === 'type') {
              const typeRes = doType(res.el, value);
              const name = res.el.placeholder || res.el.name || res.el.id || res.el.tagName;
              return { ...typeRes, summary: typeRes.success ? `Typed content into: "${name.substring(0, 30).trim()}"` : typeRes.error };
            }
            
            return { success: false, error: `Unknown action: ${actionKind}` };
          } catch (err) {
            return { success: false, error: err.message };
          }
        })();
        """
    }

    private static func escapeJSString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }
}
