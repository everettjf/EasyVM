//
//  Date.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation


// MARK: Date Utilities

extension Date {
    static func daysAgo(_ daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
    }

    func daysEqual(_ other: Date) -> Bool {
        Calendar.current.dateComponents([.day], from: self, to: other).day == 0
    }
}

extension Date {
    static let wwdc22: Date = DateComponents(
        calendar: .autoupdatingCurrent,
        timeZone: TimeZone(identifier: "PST"),
        year: 2022,
        month: 6,
        day: 6,
        hour: 9,
        minute: 41,
        second: 00).date!
}
