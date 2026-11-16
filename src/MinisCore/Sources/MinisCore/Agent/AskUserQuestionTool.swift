import Foundation

public struct UserQuestionRequest: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public let label: String
        public let description: String
        public init(label: String, description: String) { self.label = label; self.description = description }
    }
    public struct Question: Codable, Equatable, Sendable {
        public let question: String
        public let header: String
        public let options: [Option]
        public let multiSelect: Bool
        public init(question: String, header: String, options: [Option], multiSelect: Bool = false) {
            self.question = question; self.header = header; self.options = options; self.multiSelect = multiSelect
        }
        private enum CodingKeys: String, CodingKey { case question, header, options, multiSelect }
        // 模型常省略 multiSelect：缺省按单选处理，不能因缺这个字段让整张提问卡解码失败。
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            question = try container.decode(String.self, forKey: .question)
            header = try container.decode(String.self, forKey: .header)
            options = try container.decode([Option].self, forKey: .options)
            multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        }
    }
    public static let maxQuestionCharacters = 400
    public static let maxLabelCharacters = 80
    public static let maxDescriptionCharacters = 400
    public static let maxOtherCharacters = 1000
    public let questions: [Question]
    public init(questions: [Question]) { self.questions = questions }

    public func validate() throws {
        guard (1...4).contains(questions.count), Set(questions.map(\.question)).count == questions.count else {
            throw AskUserQuestionTool.InputError.invalidQuestions
        }
        for question in questions {
            guard !question.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  question.question.count <= Self.maxQuestionCharacters,
                  !question.header.isEmpty, question.header.count <= 12,
                  (2...4).contains(question.options.count),
                  Set(question.options.map(\.label)).count == question.options.count,
                  question.options.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.label.count <= Self.maxLabelCharacters
                      && !$0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.description.count <= Self.maxDescriptionCharacters }) else {
                throw AskUserQuestionTool.InputError.invalidQuestions
            }
        }
        guard try JSONEncoder().encode(self).count <= 24 * 1024 else {
            throw AskUserQuestionTool.InputError.invalidQuestions
        }
    }
}

public struct UserQuestionResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case answered, cancelled, needsClarification }
    public let status: Status
    public let questions: [UserQuestionRequest.Question]
    public let answers: [String: [String]]
    public let reason: String?
    public init(status: Status, request: UserQuestionRequest, answers: [String: [String]], reason: String? = nil) {
        self.status = status; self.questions = status == .needsClarification ? request.questions : []; self.answers = answers; self.reason = reason
    }
    public func encoded() throws -> String {
        guard answers.count <= 4, answers.allSatisfy({ key, values in
            key.count <= UserQuestionRequest.maxQuestionCharacters && values.count <= 5
                && values.allSatisfy { $0.count <= UserQuestionRequest.maxOtherCharacters }
        }) else { throw AskUserQuestionTool.InputError.resultTooLarge }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 32 * 1024 else { throw AskUserQuestionTool.InputError.resultTooLarge }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum AskUserQuestionTool {
    public static let toolName = "ask_user"
    public enum InputError: Error, LocalizedError {
        case invalidQuestions, unavailable, alreadyPending, resultTooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidQuestions: "澄清问题须为1–4题，每题2–4个不同选项及描述，标题最多12字，题目/描述最多400字，选项最多80字，题卡编码合计最多24 KiB。"
            case .alreadyPending: "本会话已有待回答的问题，请先回答或取消。"
            case .resultTooLarge: "回答结果超过32 KiB或单个回答1000字上限，请缩短其他回答后重试。"
            case .unavailable: "此执行入口没有可用的会话澄清界面。"
            }
        }
    }
    public struct NeedsClarification: Error, Sendable {
        public let result: String
        public init(request: UserQuestionRequest) throws {
            self.result = try UserQuestionResult(status: .needsClarification, request: request, answers: [:],
                reason: "子智能体不可向用户提问，请父会话澄清后重新安排任务。").encoded()
        }
    }
    public static func parse(_ input: [String: Any]) throws -> UserQuestionRequest {
        guard let json = input["questions_json"] as? String, json.utf8.count <= 64 * 1024 else { throw InputError.invalidQuestions }
        let questions = try JSONDecoder().decode([UserQuestionRequest.Question].self, from: Data(json.utf8))
        let request = UserQuestionRequest(questions: questions)
        try request.validate()
        return request
    }
    public static func definition() -> AgentToolDefinition {
        AgentToolDefinition(name: toolName,
            description: "Ask the user one to four multiple-choice questions and wait. Use it only for a decision that is truly the user's (several reasonable approaches, costly or irreversible choices, missing preference); first resolve anything you can learn by reading files or running read-only checks, and if a safe default exists state the assumption and proceed. In plan mode, clarification must go through this tool, not prose bullets. Do not use it to ask for permission, to confirm a plan (the plan is the approval request), or in unattended runs. Make each question self-contained: the user may see only the dialog. Put your recommended option first. A choice answers a question only; it never executes an action or grants approval. The result has status answered, cancelled or needsClarification; on cancelled, proceed on your best stated assumption without re-asking the same question; if the answer was required for an irreversible step, skip that step and say so. Only one question set can be pending per session. Unavailable to sub-agents.",
            parameters: ["questions_json": AgentToolParam(type: .string,
                description: "JSON string: array of 1–4 distinct questions {question (≤400 chars), header (≤12 chars), options:[{label (≤80, unique), description (≤400)}] (2–4 each), multiSelect (bool, optional, default false)}. Total ≤24 KiB. Do not add an Other option; the UI always provides a free-text one (answers ≤1000 chars)")],
            required: ["questions_json"])
    }
}
