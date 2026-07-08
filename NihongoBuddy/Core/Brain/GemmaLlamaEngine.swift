import Foundation
import CLlama

/// llama.cpp implementation: Gemma 4 E2B (GGUF) + BF16 audio projector via the
/// mtmd API. Audio goes straight into the model — no STT stage (§3).
///
/// Constraints validated in docs/VALIDATION.md (llama.cpp pinned build 9870):
///   - Gemma 4 chat template: <|turn>role\n…<turn|>\n, generation ends at EOG
///   - model may emit a thinking channel (<|channel>thought … <channel|>);
///     ThoughtChannelFilter strips it from the stream
///   - KV cache persists across turns: system prompt + prior turns stay
///     resident, only the new user turn is prefilled each turn (§3.4)
actor GemmaLlamaEngine: BrainEngine {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var mtmdContext: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var nPast: llama_pos = 0
    private var systemPromptEvaluated = false
    private let cancelFlag = CancelFlag()

    private static let nCtx: Int32 = 8192
    private static let nBatch: Int32 = 2048
    private static let nPredictMax = 320

    struct EngineError: Error, CustomStringConvertible {
        let description: String
    }

    func warmUp() async throws {
        guard model == nil else { return }

        // Keep the console usable: only warnings/errors from llama.cpp/ggml.
        llama_log_set({ level, text, _ in
            if level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text {
                fputs(String(cString: text), stderr)
            }
        }, nil)

        llama_backend_init()

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999 // full Metal offload

        guard let model = llama_model_load_from_file(ModelManager.mainModelURL.path, modelParams) else {
            throw EngineError(description: "Failed to load model at \(ModelManager.mainModelURL.path)")
        }
        self.model = model

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(Self.nCtx)
        contextParams.n_batch = UInt32(Self.nBatch)

        guard let context = llama_init_from_model(model, contextParams) else {
            throw EngineError(description: "Failed to create llama context")
        }
        self.context = context

        var mtmdParams = mtmd_context_params_default()
        mtmdParams.use_gpu = true
        mtmdParams.print_timings = false
        guard let mtmdContext = mtmd_init_from_file(ModelManager.mmprojURL.path, model, mtmdParams) else {
            throw EngineError(description: "Failed to load audio projector at \(ModelManager.mmprojURL.path)")
        }
        guard mtmd_support_audio(mtmdContext) else {
            throw EngineError(description: "mmproj does not support audio input")
        }
        self.mtmdContext = mtmdContext

        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(64, 1.06, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(64))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(1.0))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0..<UInt32.max)))
        self.sampler = chain
    }

    func generate(input: BrainInput, history: [HistoryTurn], systemPrompt: String) -> AsyncThrowingStream<String, Error> {
        cancelFlag.reset()
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.runTurn(input: input, history: history,
                                           systemPrompt: systemPrompt, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated func cancelGeneration() {
        cancelFlag.cancel()
    }

    // MARK: - Turn evaluation

    private func runTurn(input: BrainInput,
                         history: [HistoryTurn],
                         systemPrompt: String,
                         continuation: AsyncThrowingStream<String, Error>.Continuation) throws {
        guard let context, let mtmdContext, let sampler, let model else {
            throw EngineError(description: "Engine not warmed up")
        }

        try makeRoomIfNeeded()

        // History lives in the KV cache — only the new turn is prefilled.
        // On a fresh cache (app start, or after an overflow wipe) the KV holds
        // nothing, so replay the transcript history in text form first —
        // otherwise the model greets every turn with amnesia.
        var prompt = ""
        // Model turns are replayed IN the output frame — bare-text model turns
        // teach the model to answer without the frame (it imitates its own
        // history), which breaks the parser downstream.
        if !systemPromptEvaluated {
            prompt += "<|turn>system\n\(systemPrompt)<turn|>\n"
            var lastUserText = ""
            for turn in history {
                switch turn.role {
                case .user:
                    lastUserText = turn.text
                    prompt += "<|turn>user\n\(turn.text)<turn|>\n"
                case .assistant:
                    prompt += "<|turn>model\n<heard>\(lastUserText)</heard>\n"
                    prompt += "<reply emotion=\"neutral\">\(turn.text)</reply><turn|>\n"
                }
            }
        }
        let marker = String(cString: mtmd_default_marker())

        var bitmap: OpaquePointer?
        defer { if let bitmap { mtmd_bitmap_free(bitmap) } }

        // The model turn is prefilled with "<heard>" so generation must continue
        // the output frame directly — this suppresses the thinking channel
        // (which <|think|>off alone does not) and enforces frame adherence.
        switch input {
        case .audio(let samples):
            prompt += "<|turn>user\n\(marker)<turn|>\n<|turn>model\n<heard>"
            bitmap = samples.withUnsafeBufferPointer { buf in
                mtmd_bitmap_init_from_audio(samples.count, buf.baseAddress)
            }
            guard bitmap != nil else { throw EngineError(description: "Failed to build audio bitmap") }
        case .text(let text):
            prompt += "<|turn>user\n\(text)<turn|>\n<|turn>model\n<heard>"
        }

        guard let chunks = mtmd_input_chunks_init() else {
            throw EngineError(description: "Failed to allocate input chunks")
        }
        defer { mtmd_input_chunks_free(chunks) }

        var inputText = mtmd_input_text(
            text: strdup(prompt),
            add_special: !systemPromptEvaluated, // BOS only at conversation start
            parse_special: true
        )
        defer { free(UnsafeMutablePointer(mutating: inputText.text)) }

        let tokenizeResult: Int32
        if let bitmap {
            var bitmaps: [OpaquePointer?] = [bitmap]
            tokenizeResult = mtmd_tokenize(mtmdContext, chunks, &inputText, &bitmaps, 1)
        } else {
            tokenizeResult = mtmd_tokenize(mtmdContext, chunks, &inputText, nil, 0)
        }
        guard tokenizeResult == 0 else {
            throw EngineError(description: "mtmd_tokenize failed with code \(tokenizeResult)")
        }

        var newNPast: llama_pos = 0
        let evalResult = mtmd_helper_eval_chunks(mtmdContext, context, chunks,
                                                 nPast, 0, Self.nBatch,
                                                 /* logits_last */ true, &newNPast)
        guard evalResult == 0 else {
            throw EngineError(description: "prefill failed with code \(evalResult)")
        }
        nPast = newNPast
        systemPromptEvaluated = true

        // The prefilled frame opener is part of the prompt, not the generation —
        // replay it into the stream so the parser sees a complete frame.
        continuation.yield("<heard>")

        // Sampling loop — stream pieces out as they are generated.
        let vocab = llama_model_get_vocab(model)
        var thoughtFilter = ThoughtChannelFilter()
        var pieceBuffer = [CChar](repeating: 0, count: 256)

        for _ in 0..<Self.nPredictMax {
            if cancelFlag.isCancelled { break }

            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }

            let pieceLength = llama_token_to_piece(vocab, token, &pieceBuffer, Int32(pieceBuffer.count), 0, true)
            if pieceLength > 0 {
                let piece = String(decoding: pieceBuffer[0..<Int(pieceLength)].map { UInt8(bitPattern: $0) },
                                   as: UTF8.self)
                #if DEBUG
                print(piece, terminator: "")
                #endif
                if let visible = thoughtFilter.push(piece), !visible.isEmpty {
                    continuation.yield(visible)
                }
            }

            var batch = llama_batch_get_one(&token, 1)
            guard llama_decode(context, batch) == 0 else {
                throw EngineError(description: "decode failed mid-generation")
            }
            nPast += 1
        }

        // Flush the filter's held-back tail or the reply loses its last characters.
        if let tail = thoughtFilter.flush(), !tail.isEmpty {
            continuation.yield(tail)
        }

        #if DEBUG
        print("\n=== generation finished (n_past \(nPast)) ===")
        #endif

        // Close the model turn in the KV cache so the next turn appends cleanly.
        try evalText("<turn|>\n")
    }

    /// Evaluate a small text suffix into the KV cache (no logits needed).
    private func evalText(_ text: String) throws {
        guard let context, let model else { return }
        let vocab = llama_model_get_vocab(model)
        var tokens = [llama_token](repeating: 0, count: text.utf8.count + 8)
        let count = llama_tokenize(vocab, text, Int32(text.utf8.count), &tokens, Int32(tokens.count), false, true)
        guard count > 0 else { return }
        tokens.removeSubrange(Int(count)...)
        var batch = llama_batch_get_one(&tokens, count)
        guard llama_decode(context, batch) == 0 else {
            throw EngineError(description: "decode failed appending turn suffix")
        }
        nPast += count
    }

    /// User started a new conversation: wipe the KV cache so the next turn
    /// re-evaluates the system prompt with no prior turns.
    func resetConversation() {
        guard let context else { return }
        let memory = llama_get_memory(context)
        llama_memory_seq_rm(memory, 0, 0, -1)
        nPast = 0
        systemPromptEvaluated = false
    }

    /// Context-overflow guard: when the KV cache nears n_ctx, drop everything
    /// after the system prompt. Simple v1 policy; MistakeStore carries the
    /// long-term memory (§3.7).
    private func makeRoomIfNeeded() throws {
        guard nPast > Self.nCtx - 1024, let context else { return }
        let memory = llama_get_memory(context)
        llama_memory_seq_rm(memory, 0, 0, -1)
        nPast = 0
        systemPromptEvaluated = false
    }
}

/// Strips the model's thinking channel (<|channel>thought … <channel|>) from
/// the visible token stream. Everything outside a channel span passes through.
struct ThoughtChannelFilter {
    private var inThought = false
    private var pending = ""

    /// Emit whatever is still held back — call once at end of stream.
    mutating func flush() -> String? {
        defer { pending = ""; inThought = false }
        return inThought || pending.isEmpty ? nil : pending
    }

    mutating func push(_ piece: String) -> String? {
        pending += piece
        var visible = ""
        while !pending.isEmpty {
            if inThought {
                if let end = pending.range(of: "<channel|>") {
                    pending.removeSubrange(..<end.upperBound)
                    inThought = false
                } else {
                    pending = String(pending.suffix(12)) // keep tail for split tag
                    return visible.isEmpty ? nil : visible
                }
            } else if let start = pending.range(of: "<|channel>") {
                visible += pending[..<start.lowerBound]
                pending.removeSubrange(..<start.upperBound)
                // Skip the channel name (e.g. "thought"); content ends at <channel|>.
                inThought = true
            } else {
                // Hold back a small tail in case "<|channel>" is split across pieces.
                let safeCount = max(0, pending.count - 12)
                if safeCount > 0 {
                    let idx = pending.index(pending.startIndex, offsetBy: safeCount)
                    visible += pending[..<idx]
                    pending.removeSubrange(..<idx)
                }
                return visible.isEmpty ? nil : visible
            }
        }
        return visible.isEmpty ? nil : visible
    }
}

/// Thread-safe cancellation flag readable from the C sampling loop and
/// settable from any thread without hopping onto the busy engine actor.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }

    func reset() {
        lock.lock(); value = false; lock.unlock()
    }
}
