import Foundation

// MARK: - Phrasebook

/// Ready phrases for one situation, in your language and theirs, kept on the phone so they work offline.
public struct PhraseSection: Codable, Equatable, Identifiable, Sendable {
    public struct Phrase: Codable, Equatable, Identifiable, Sendable {
        public var mine: String
        public var theirs: String
        /// How to say it, in Latin letters (for scripts you can't read).
        public var reading: String?
        public var id: String { mine + "|" + theirs }

        public init(mine: String, theirs: String, reading: String? = nil) {
            self.mine = mine
            self.theirs = theirs
            self.reading = reading
        }
    }

    public var situation: String
    public var phrases: [Phrase]
    public var id: String { situation }

    public init(situation: String, phrases: [Phrase]) {
        self.situation = situation
        self.phrases = phrases
    }
}

public struct Phrasebook: Codable, Equatable, Sendable {
    public var mine: String
    public var theirs: String
    public var sections: [PhraseSection]
    public var createdAt: Date

    public init(mine: String, theirs: String, sections: [PhraseSection], createdAt: Date = Date()) {
        self.mine = mine
        self.theirs = theirs
        self.sections = sections
        self.createdAt = createdAt
    }

    public static let situations = ["Greetings and basics", "Restaurant", "Shop and market", "Taxi and transport", "Hotel",
                                    "Directions", "Pharmacy and doctor", "Emergency", "Money and paying", "Small talk"]

    public static func prompt(mine: String, theirs: String, situations: [String] = situations) -> String {
        """
        Make a travel phrasebook for someone who speaks \(mine) visiting a place where people speak \(theirs). \
        For each situation below give 10–12 short, natural phrases a traveller really needs, in \(mine) and in \(theirs) \
        (written in \(theirs)'s own script), with a Latin-letter reading when that script is not Latin (else leave it empty).

        Situations: \(situations.joined(separator: "; ")).

        Answer with one fenced JSON block only:
        ```json
        {"sections": [{"situation": "Restaurant", "phrases": [{"mine": "…", "theirs": "…", "reading": "…"}]}]}
        ```
        """
    }

    public static func parse(_ reply: String, mine: String, theirs: String) -> Phrasebook? {
        guard let json = TaskReview.lastJSON(reply) else { return nil }
        let sections: [PhraseSection] = (json["sections"]?.array ?? []).compactMap { s in
            guard let name = s["situation"]?.string else { return nil }
            let phrases: [PhraseSection.Phrase] = (s["phrases"]?.array ?? []).compactMap { p in
                guard let m = p["mine"]?.string, let t = p["theirs"]?.string, !m.isEmpty, !t.isEmpty else { return nil }
                let reading = p["reading"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                return PhraseSection.Phrase(mine: m, theirs: t, reading: reading)
            }
            return phrases.isEmpty ? nil : PhraseSection(situation: name, phrases: phrases)
        }
        return sections.isEmpty ? nil : Phrasebook(mine: mine, theirs: theirs, sections: sections)
    }
}

// MARK: - Receipts

/// A photographed receipt or bill, read line by line, to convert and split.
public struct Receipt: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// What the line costs (quantity included), in the receipt's currency.
        public var price: Double
        public var quantity: Int

        public init(id: String = UUID().uuidString, name: String, price: Double, quantity: Int = 1) {
            self.id = id
            self.name = name
            self.price = price
            self.quantity = quantity
        }
    }

    public var items: [Item]
    /// ISO code, e.g. JPY.
    public var currency: String
    /// Tax, service and the like that are not items.
    public var extras: Double
    /// The total printed on the receipt, when there is one.
    public var printedTotal: Double?

    public init(items: [Item], currency: String, extras: Double = 0, printedTotal: Double? = nil) {
        self.items = items
        self.currency = currency
        self.extras = extras
        self.printedTotal = printedTotal
    }

    public var itemsTotal: Double { items.reduce(0) { $0 + $1.price } }
    public var total: Double { printedTotal ?? itemsTotal + extras }

    public static func prompt(mine: String) -> String {
        """
        Read this receipt or bill. List every line item with its name translated into \(mine) and the price for that line \
        (quantity included) as a plain number. Tax, service charge, tips or discounts that are not items go into "extras" \
        (a discount as a negative number). Give the currency as an ISO code and the total printed on it, if any.

        Answer with one fenced JSON block only:
        ```json
        {"currency": "JPY", "items": [{"name": "…", "price": 980, "quantity": 1}], "extras": 0, "total": 980}
        ```
        """
    }

    public static func parse(_ reply: String) -> Receipt? {
        guard let json = TaskReview.lastJSON(reply) else { return nil }
        func number(_ v: JSONValue?) -> Double? {
            if let d = v?.double { return d }
            return v?.string.flatMap { Double($0.replacingOccurrences(of: ",", with: "").filter { "0123456789.-".contains($0) }) }
        }
        let items: [Item] = (json["items"]?.array ?? []).compactMap { i in
            guard let name = i["name"]?.string, let price = number(i["price"]) else { return nil }
            return Item(name: name, price: price, quantity: i["quantity"]?.int ?? 1)
        }
        guard !items.isEmpty else { return nil }
        return Receipt(items: items, currency: (json["currency"]?.string ?? "").uppercased(), extras: number(json["extras"]) ?? 0,
                       printedTotal: number(json["total"]))
    }

    /// Who pays what: each item split evenly between the people it is assigned to (everyone when nobody is),
    /// extras shared in proportion to what each person had.
    public func split(people: [String], assignments: [String: Set<String>]) -> [String: Double] {
        guard !people.isEmpty else { return [:] }
        var owed = Dictionary(uniqueKeysWithValues: people.map { ($0, 0.0) })
        for item in items {
            let who = assignments[item.id].map { Array($0).filter(people.contains) } ?? []
            let payers = who.isEmpty ? people : who
            for p in payers { owed[p, default: 0] += item.price / Double(payers.count) }
        }
        let extra = total - itemsTotal
        let base = itemsTotal
        if extra != 0 {
            for p in people {
                let share = base > 0 ? (owed[p] ?? 0) / base : 1 / Double(people.count)
                owed[p, default: 0] += extra * share
            }
        }
        return owed
    }
}
