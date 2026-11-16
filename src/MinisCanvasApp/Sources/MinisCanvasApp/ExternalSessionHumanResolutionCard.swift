import SwiftUI
import MinisCore

/// Explicit human decisions over the existing supervised runtime. Rendering
/// and inspection never dispatch controls or manufacture provider outcomes.
@MainActor
struct ExternalSessionHumanResolutionCard: View {
    let composition: ExternalSessionAuthorizationComposition
    let sourceID: ExternalSessionSourceID
    let readGrant: ExternalSessionReadGrantV1?
    let controlGrant: ExternalSessionControlGrantV1?
    @State private var preview: ExternalSessionHumanResolutionPreview?
    @State private var snapshot: ExternalSessionRuntimeSnapshot?
    @State private var note = ""
    @State private var reference = ""
    @State private var operation: ExternalSessionControlOperationV1 = .resume
    @State private var input = ""
    @State private var message: String?
    @State private var isBusy = false
    @State private var confirmLocal = false
    @State private var confirmCompensation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("原操作结果未知")
                .font(.headline)
                .accessibilityIdentifier("external-session-unknown-outcome")
            Text("状态查询不能证明原操作已执行或未执行。下面两项是独立的人工决定；都保留原 UNKNOWN 历史。")
                .font(.caption)
            if let original = snapshot?.unconfirmedControl {
                Text("来源 \(original.sourceID.rawValue) · 配置 \(original.profileID.rawValue)")
                Text("会话 \(original.threadID.rawValue) · 回合 \(original.turnID?.rawValue ?? "无回合 ID") · 原操作 \(original.operation.rawValue)")
                Text("原授权 \(original.controlAuthorizationID.rawValue) · epoch \(original.controlRevocationEpoch) · generation \(original.connectionGeneration) · owner \(original.connectionOwnerID)")
                Text("原请求 \(original.requestIdentity?.localOperationID ?? "旧记录未提供") · 状态观察 \(original.observedTurnStatus?.rawValue ?? "未观察")（不是操作回执）")
                Button("检查原目标并准备人工确认") { Task { await inspect() } }
                    .disabled(isBusy || readGrant == nil || controlGrant == nil)
                    .accessibilityIdentifier("external-session-human-inspect")
                TextField("处理说明（不填写口令）", text: $note)
                TextField("处理依据或引用（不填写口令）", text: $reference)
                Button("记录已在外部处理，允许重新连接后执行新操作…") { confirmLocal = true }
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("external-session-human-local-disposition")
                Picker("独立补偿操作", selection: $operation) {
                    ForEach([ExternalSessionControlOperationV1.resume, .fork, .steer].filter {
                        controlGrant?.operations.contains($0) == true
                    }, id: \.rawValue) { Text($0.rawValue).tag($0) }
                }
                if operation == .steer { TextField("本次独立补偿指令", text: $input) }
                Button("单独授权并发送一次独立补偿…") { confirmCompensation = true }
                    .disabled(!canConfirm || controlGrant?.operations.contains(operation) != true)
                    .accessibilityIdentifier("external-session-human-independent-compensation")
            }
            if let snapshot, !(snapshot.humanResolutionHistory ?? []).isEmpty {
                ForEach(snapshot.humanResolutionHistory ?? [], id: \.decisionID) { receipt in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("人工记录 \(receipt.decisionID) · \(receipt.decision.rawValue)")
                        Text("原操作 \(receipt.original.operation.rawValue) 的结果仍未知；\(receipt.outcome.rawValue)")
                        Text("来源 \(receipt.decisionSource.rawValue) · 决定者 \(receipt.actor.rawValue) · \(receipt.redactedNote) · \(receipt.redactedSourceReference)")
                    }
                    .accessibilityIdentifier("external-session-human-history")
                }
                ForEach(snapshot.independentCompensationReceipts ?? [], id: \.decisionID) { receipt in
                    Text("独立补偿请求 \(receipt.independentIdentity.localOperationID) · \(receipt.providerReceipt.operation.rawValue) · 新回执 \(receipt.providerReceipt.outcome.rawValue)；原 UNKNOWN 不变")
                        .accessibilityIdentifier("external-session-independent-receipt")
                }
                if snapshot.state == .disconnected,
                   composition.hasConfiguredSyntheticCodexControl(for: sourceID) {
                    Button("以当前授权重新建立控制连接") { Task { await reconnect() } }
                        .disabled(isBusy || readGrant == nil || controlGrant == nil)
                        .accessibilityIdentifier("external-session-human-new-handshake")
                }
            }
            if let message { Text(message).textSelection(.enabled) }
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .task(id: sourceID) { refresh() }
        .alert("记录本地人工处置？", isPresented: $confirmLocal) {
            Button("取消", role: .cancel) {}
            Button("仅记录本地处置") { Task { await submit(.recordExternalHandlingAndAllowNewControls) } }
        } message: {
            Text("原操作结果仍未知。本次仅记录你已在外部处理的决定，不发送补偿、不生成原操作成功/失败回执。\n说明：\(note)\n依据：\(reference)")
        }
        .alert("单独发送一次独立补偿？", isPresented: $confirmCompensation) {
            Button("取消", role: .cancel) {}
            Button("仅授权这次独立补偿") { Task { await submit(.authorizeOneIndependentCompensation) } }
        } message: {
            Text("原操作结果仍未知。本次是新请求，只生成新请求的回执，不记录已在外部处理。\n目标：\(preview?.original.threadID.rawValue ?? "未检查") / \(preview?.original.turnID?.rawValue ?? "无回合 ID")\n操作：\(operation.rawValue)\n指令：\(operation == .steer ? input : "无")\n说明：\(note)\n依据：\(reference)")
        }
    }

    private var canConfirm: Bool {
        preview != nil && !isBusy && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && note.count <= 512 && reference.count <= 512
    }

    private func refresh() { snapshot = composition.adapter(for: sourceID)?.runtimeSnapshot }

    private func inspect() async {
        guard let readGrant, let controlGrant else { return }
        isBusy = true
        defer { isBusy = false; refresh() }
        do {
            preview = try await composition.previewHumanResolution(sourceID: sourceID,
                readGrant: readGrant, controlGrant: controlGrant)
            operation = controlGrant.operations.contains(.resume) ? .resume
                : controlGrant.operations.contains(.fork) ? .fork : .steer
            message = "已检查原目标；状态只是观察，原操作结果仍未知。"
        } catch { preview = nil; message = "检查失败：\(error)" }
    }

    private func submit(_ decision: ExternalSessionHumanDecision) async {
        guard let preview, let controlGrant, let readGrant else { return }
        isBusy = true
        defer { isBusy = false; self.preview = nil; refresh() }
        do {
            let proposal: ExternalSessionIndependentCompensationProposal? = decision == .authorizeOneIndependentCompensation
                ? ExternalSessionIndependentCompensationProposal(sourceID: sourceID,
                    profileID: preview.original.profileID, threadID: preview.original.threadID,
                    turnID: preview.original.turnID, operation: operation,
                    boundedInput: operation == .steer ? input : nil) : nil
            let receipt = try await composition.submitHumanResolution(sourceID: sourceID,
                preview: preview, decision: decision, note: note, sourceReference: reference,
                compensationProposal: proposal, controlGrant: controlGrant)
            if let proposal {
                let result = try await composition.performIndependentCompensation(sourceID: sourceID,
                    decisionReceiptID: receipt.decisionID, proposal: proposal,
                    readGrant: readGrant, controlGrant: controlGrant)
                message = "独立补偿的新回执：\(result.providerReceipt.outcome.rawValue)；持久化：\(result.auditPersistence.rawValue)。原操作结果仍未知。"
            } else {
                message = "人工处置已记录；原操作结果仍未知。须重新连接后才能执行新操作。"
            }
        } catch { message = "本次处理未完成：\(error)。原操作结果仍未知，请重新检查；不会自动重放。" }
    }

    private func reconnect() async {
        guard let readGrant, let controlGrant else { return }
        isBusy = true
        defer { isBusy = false; refresh() }
        do {
            try await composition.activateSyntheticCodexControl(sourceID: sourceID,
                readGrant: readGrant, controlGrant: controlGrant)
            message = "已建立新连接；只允许当前授权下的新请求，旧操作历史仍 UNKNOWN。"
        } catch { message = "新连接失败：\(error)" }
    }
}
