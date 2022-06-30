//
//  FoodItem.swift
//  EasyVM
//
//  Created by gipyzarc on 2022/6/29.
//
import Foundation

// MARK: Food Models

/// A model representing a food with a price and quantity.
struct FoodItem: Hashable, Identifiable, Codable, Equatable {
    let emoji: String
    let name: String
    var description: String = ""
    let price: Decimal
    var quantity: Int = 0
    var id: String { name }
}

let donut = FoodItem(emoji: "🍩", name: "Doughnut", description: "Yeast, Old-fashioned, Cake, and the dubious Apple Fritter", price: 2.35, quantity: 6)
let moonCake = FoodItem(emoji: "🥮", name: "Moon Cake", description: "Lotus seed paste — plenty of crust", price: 2.20, quantity: 4)
let shavedIce = FoodItem(emoji: "🍧", name: "Shaved Ice", description: "Shave your own ice!", price: 3.25, quantity: 1)
let cupcake = FoodItem(emoji: "🧁", name: "Cupcake", description: "Also goes by the name Cake Nano", price: 4.00, quantity: 5)
let flan = FoodItem(emoji: "🍮", name: "Flan", description: "What's in a flan? That which we call milk, eggs, and sugar by any other name would taste just as sweet.", price: 6.50, quantity: 2)
let taffy = FoodItem(emoji: "🍬", name: "Taffy", description: "Freshwater, actually.", price: 1.00, quantity: 11)
let cake = FoodItem(emoji: "🎂", name: "Cake Cake", description: "The real deal", price: 15.00, quantity: 1)
let cookie = FoodItem(emoji: "🍪", name: "Cookie Cake", description: "The ultimate dessert", price: 4.30, quantity: 1)

let relatedFoods = [donut, moonCake, shavedIce, cupcake, flan, taffy, cake, cookie]

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

let partyFoods = [
    FoodItem(emoji: "🍨", name: "Ice Cream",
             price: 3.50, quantity: 4),
    flan,
    taffy,
    donut,
    FoodItem(emoji: "🍉", name: "Watermelon",
             price: 3.65, quantity: 1),
    FoodItem(emoji: "🍒", name: "Cherries",
             price: 8.00, quantity: 1),
    cupcake,
    cookie,
    FoodItem(emoji: "🍥", name: "Fish Cake",
             price: 5.00, quantity: 2),
    moonCake,
    cake,
    FoodItem(emoji: "🍘", name: "Rice Cracker",
             price: 0.25, quantity: 16),
    FoodItem(emoji: "🥨", name: "Pretzels",
             price: 3.00, quantity: 3),
    shavedIce,
    FoodItem(emoji: "🥧", name: "Apple Pie",
             price: 4.10, quantity: 1)
]
