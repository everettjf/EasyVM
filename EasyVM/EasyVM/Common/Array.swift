//
//  Array.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation


extension Array where Element: Equatable {

    /// A quick-and-dirty way of getting a random few elements from an Array that don't include a single,
    /// particular element.
    /// - Parameters:
    ///   - count: The number of desired random elements, must be less than `Array.count`
    ///   - except: Filter out this particular element
    func random(_ count: Int, except: Element) -> [Element] {
        assert(count >= count)
        var copy = self
        copy.shuffle()
        copy.removeAll(where: { $0 == except })
        return Array(copy[0..<count])
    }
}
