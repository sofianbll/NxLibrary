import Foundation

package struct ActivityHistory {
    package enum Job: Equatable, Codable, Sendable {
        case build(BuildRequest)
        case cloud(CloudTransferQueue.Entry)
        case move(LibraryMoveRequest)
    }

    package enum Outcome: Equatable, Codable, Sendable {
        case succeeded, failed(String), cancelled
    }

    package struct Result: Identifiable, Codable, Sendable {
        package let id: UUID
        package let job: Job
        package let name: String?
        package let outcome: Outcome

        package var canRetry: Bool {
            if case .failed = outcome { return true }
            return false
        }
    }

    package private(set) var entries: [Result] = []

    package init() {}

    package mutating func restore(_ previous: [Result]) {
        var seen = Set(entries.map(\.id))
        entries += previous.filter { result in
            if case .build(let request) = result.job, result.id != request.id { return false }
            if case .cloud(let request) = result.job, let token = request.token, token != result.id { return false }
            return seen.insert(result.id).inserted
        }
    }

    package mutating func record(id: UUID, job: Job, name: String?, outcome: Outcome) {
        clear(id)
        entries.insert(.init(id: id, job: job, name: name, outcome: outcome), at: 0)
    }

    package mutating func clear(_ id: UUID? = nil) {
        if let id { entries.removeAll { $0.id == id } }
        else { entries.removeAll() }
    }

    package func retry(_ id: UUID, submit: (Result) -> Bool) -> Bool {
        guard let result = entries.first(where: { $0.id == id && $0.canRetry }) else { return false }
        return submit(result)
    }
}

package struct LibraryMoveRequest: Equatable, Codable, Sendable {
    package let plan: CloudDriveFolders.MovePlan
    package let destination: String

    package init(plan: CloudDriveFolders.MovePlan, destination: String) {
        self.plan = plan
        self.destination = destination
    }
}
