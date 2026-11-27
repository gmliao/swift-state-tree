import SwiftStateTurns

/// A barrier machine that takes mail (#953): a mail names a key, and its step releases the
/// callers waiting on it through `MailTurn.release(where:)`. For the mailbox paths of the barrier:
/// a release by mail, a claim by mail, a cancellation's mailbox take, and the ordinals a barrier's
/// entries take.
@PlainData
struct BarrierMailMachine: TurnMachine {
    enum Input: Sendable {
        /// Waits its caller on `key` holding `payload`, with an optional budget in seconds.
        case wait(String, payload: Int, timeoutSeconds: Int64?)
    }

    enum Effect: Sendable {}

    typealias Output = Int
    typealias Key = String
    typealias Reply = Int
    typealias Mail = String
    typealias BarrierKey = String
    typealias BarrierPayload = Int

    var log: [String] = []
    var callers: [Int: InputID] = [:]

    init() {}

    mutating func handle(_ input: Input, _ turn: inout Turn<BarrierMailMachine>) {
        switch input {
        case .wait(let key, let payload, let seconds):
            guard let caller = turn.input else { return }
            callers[payload] = caller
            switch turn.wait(caller, on: key, holding: payload, timeout: seconds.map { .seconds($0) }) {
            case .waiting: log.append("waiting \(payload) on \(key)")
            case .refused(let held, let why):
                log.append("refused \(held) \(why)")
                turn.reply(to: caller, .failure(CancellationError()))
            case .expired(let held):
                log.append("expired \(held)")
                turn.reply(to: caller, .failure(TurnError.timedOut))
            }
        }
    }

    mutating func handleMail(_ mail: String, _ turn: inout MailTurn<BarrierMailMachine>) {
        // "claim N": replies to payload N's waiting caller directly, which claims it.
        if mail.hasPrefix("claim "), let payload = Int(mail.dropFirst(6)), let caller = callers[payload] {
            log.append("mail claims \(payload)")
            turn.reply(to: caller, .success(payload * 10))
            return
        }
        log.append("mail \(mail): \(turn.waiterCount(on: mail)) waiting")
        for r in turn.release(where: { $0 == mail }) {
            log.append("released \(r.payload) by mail")
            turn.reply(to: r.caller, .success(r.payload))
        }
    }

    mutating func handleWaitEnded(_ ended: ReleasedWait<BarrierMailMachine>, _ why: WaitEnd, _ turn: inout Turn<BarrierMailMachine>) {
        log.append("ended \(ended.payload) \(why)")
        if let error = why.error { turn.reply(to: ended.caller, .failure(error)) }
    }
}
