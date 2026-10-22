#if canImport(UIKit)
// Rich answers Corey and Denise give the demo household in the screenshot states: one
// of every card, as the steward-cards skill tells them to write it. Every figure here is
// made up.

import Foundation

enum RichAnswers {
    static let groceriesByWeek = #"""
    Three weeks so far, $391 in all.

    ```steward-card
    {"type":"chart","title":"Grocery spend by week","kind":"bar","x":["W1","W2","W3"],"series":[{"name":"Spend","values":[142,118,131]}],"unit":"$"}
    ```

    ```steward-card
    {"type":"table","columns":["Store","Trips","Spend"],"rows":[["Corner market",5,"$171"],["Big box store",2,"$146"],["Farmers market",3,"$74"]]}
    ```
    """#

    static let groceriesByMonth = #"""
    Down three months in a row.

    ```steward-card
    {"type":"chart","title":"Grocery spend by month","kind":"line","x":["May","Jun","Jul","Aug","Sep","Oct"],"series":[{"name":"Spend","values":[512,468,530,489,455,391]}],"unit":"$"}
    ```

    | Month | Spend | Vs. avg |
    |:---|---:|---:|
    | Aug | $489 | +$15 |
    | Sep | $455 | -$19 |
    | Oct | $391 | -$83 |
    """#

    static let saturday = #"""
    Here is Saturday.

    ```steward-card
    {"type":"checklist","id":"shopping","title":"Shopping list","items":[{"text":"Milk","done":true},{"text":"Eggs","done":true},{"text":"Basil","done":false},{"text":"Parmesan","done":false}],"skill":"lists"}
    ```

    ```steward-card
    {"type":"reminder","text":"Leave for soccer pickup","at":"2026-10-17T17:30:00-04:00"}
    ```

    ```steward-card
    {"type":"event","title":"Movie night","start":"2026-10-16T20:00:00-04:00","end":"2026-10-16T22:00:00-04:00","location":"Living room","skill":"calendar"}
    ```
    """#

    /// The shopping list Corey read while he planned Saturday.
    static let shoppingList = #"""
    ```steward-card
    {"type":"checklist","id":"shopping","title":"Shopping list","items":[{"text":"Milk","done":false},{"text":"Eggs","done":false},{"text":"Pasta","done":false},{"text":"Basil","done":false},{"text":"Parmesan","done":false}],"skill":"lists"}
    ```
    """#

    /// What to do before Friday's field trip, a list Corey sees every tick of.
    static let beforeTheTrip = #"""
    ```steward-card
    {"type":"checklist","id":"before-trip","title":"Before the trip","items":[{"text":"Sign the permission slip","done":false},{"text":"Pack lunch","done":false},{"text":"Fill the water bottle","done":false}]}
    ```
    """#

    /// A reminder Corey set, on its own.
    static let pickupReminder = #"""
    Done. I will remind you on Saturday.

    ```steward-card
    {"type":"reminder","text":"Leave for soccer pickup","at":"2026-10-17T17:30:00-04:00"}
    ```
    """#

    /// A text Corey drafted for Franco to send Gia from his own iPhone.
    static let textGia = #"""
    Here it is, ready for you to send.

    ```steward-card
    {"type":"message","to":"Gia","text":"Running 10 minutes late, start dinner without me."}
    ```
    """#

    /// A text Corey drafted for Franco to send Sarah, with movie night riding in it.
    static let movieNightForSarah = #"""
    Here it is, with the invite.

    ```steward-card
    {"type":"message","to":"Sarah","text":"Movie night Friday at 8 at our place. The invite is attached.","event":{"title":"Movie night","start":"2026-10-23T20:00:00-04:00","end":"2026-10-23T22:00:00-04:00","location":"Living room"}}
    ```
    """#

    /// The household cart after Corey added the candles: Daisy's example, as her gateway
    /// sends it.
    static func householdCart() throws -> String {
        let cart = try Fixtures.text("cards/cart").trimmingCharacters(in: .whitespacesAndNewlines)
        return "Added birthday candles. It has no Amazon link yet, so it stays out of checkout.\n\n```steward-card\n\(cart)\n```"
    }

    /// Franco's order on its way: Daisy's example, as her gateway sends it.
    static func householdOrder() throws -> String {
        let order = try Fixtures.text("cards/order").trimmingCharacters(in: .whitespacesAndNewlines)
        return "It shipped this morning.\n\n```steward-card\n\(order)\n```"
    }

    static let schoolEmail = #"""
    This came this morning:

    ```steward-card
    {"type":"email","from":"Maple Elementary <office@maple.example>","to":["Gia","Franco"],"subject":"Field trip on Friday","body":"The bus leaves at 9:00 and is back by 3:00. Please send a packed lunch and the signed slip."}
    ```
    """#

    static let gateCodeAndBottle = #"""
    ```steward-card
    {"type":"copy","label":"Gate code","text":"4821"}
    ```

    ```steward-card
    {"type":"product","name":"Insulated water bottle for the trip","price":"$24.99","store":"Sports Corner","url":"https://example.com/bottle"}
    ```
    """#

    static let johnThreeSixteen = #"""
    ```steward-card
    {"type":"scripture","reference":"John 3:16-17","translation":"BSB","verses":[{"n":16,"text":"For God so loved the world that He gave His one and only Son, that everyone who believes in Him shall not perish but have eternal life."},{"n":17,"text":"For God did not send His Son into the world to condemn the world, but to save the world through Him."}],"link":"https://www.bible.com/bible/3034/JHN.3.16-17.BSB","skill":"scripture"}
    ```
    """#

    static let balanceAndBudget = #"""
    ```steward-card
    {"type":"pocketpiggies","card":"balance","balance":1284.5,"piggies":[{"name":"Fun","balance":210},{"name":"Savings","balance":860},{"name":"Gifts","balance":214.5}],"skill":"pocketpiggies"}
    ```

    ```steward-card
    {"type":"pocketpiggies","card":"budget","month":"October","spent":640,"limit":900,"daysLeft":9}
    ```
    """#

    static let spendingAndGoal = #"""
    ```steward-card
    {"type":"pocketpiggies","card":"spending","categories":[{"name":"Groceries","amount":284},{"name":"Dining","amount":146},{"name":"Kids","amount":120},{"name":"Fun","amount":90}],"skill":"pocketpiggies"}
    ```

    ```steward-card
    {"type":"pocketpiggies","card":"goal","name":"Beach trip","saved":680,"target":1000,"weekly":40}
    ```
    """#

    /// What the calendar skill read, in the calendar's royal.
    static let dentist = #"""
    Thursday at 3:30.

    ```steward-card
    {"type":"event","title":"Dentist, Gia","start":"2026-10-15T15:30:00-04:00","end":"2026-10-15T16:15:00-04:00","skill":"calendar"}
    ```
    """#

    /// A web search's answer and the pages it came from.
    static let poolHours = #"""
    Yes, from 7 AM on weekends this month.

    ```steward-card
    {"type":"sources","links":[{"url":"https://www.cityparks.example/pools/hours"},{"url":"https://news.example/pool-reopens","title":"news.example"}],"skill":"web"}
    ```
    """#

    /// A list the lists skill keeps, in its mint.
    static let beachList = #"""
    Added towels to the beach list.

    ```steward-card
    {"type":"checklist","id":"beach","title":"Beach trip","items":[{"text":"Sunscreen","done":true},{"text":"Towels","done":false}],"skill":"lists"}
    ```
    """#

    /// A sermon from the household's own archive.
    static let loveThatGives = #"""
    ```steward-card
    {"type":"sermon","title":"Love that gives","quote":"Love is not measured by what we keep, but by what we give away gladly.","minutes":12,"link":"https://sermons.example/love-that-gives"}
    ```
    """#

    static let philippians = #"""
    ```steward-card
    {"type":"scripture","reference":"Philippians 4:13","translation":"BSB","verses":[{"n":13,"text":"I can do all things through Christ who gives me strength."}],"link":"https://www.bible.com/bible/3034/PHP.4.13.BSB"}
    ```
    """#

    /// A card type this app does not know, which shows as its JSON.
    static let forecast = #"""
    I checked the forecast.

    ```steward-card
    {"type":"weather","city":"Boston","high":61,"low":48}
    ```
    """#

    /// What is on tonight, and three things Franco may want next, offered under it.
    static let tonight = #"""
    **Tonight**
    - 4:10 PM Gia lands
    - 6:30 PM Dinner at home
    - 8:00 PM Movie night

    Want a reminder to leave at 3:45?

    ```steward-card
    {"type":"followups","items":[{"text":"Remind me at 3:45","icon":"reminder"},{"text":"Text Gia"},{"text":"Add movie night","icon":"calendar"}]}
    ```
    """#

    /// A reply caught mid-card: the words so far, and a checklist whose block is still open.
    static let saturdayArriving = #"""
    Here is Saturday.

    ```steward-card
    {"type":"checklist","id":"shopping","title":"Shopping list","items":[{"text":"Milk","done":true},{"text":"Eg
    """#

    /// The rest of it: the card closes and the words go on.
    static let saturdayGoingOn = #"""
    gs","done":true}]}
    ```

    I also put movie night on Friday at 8, and I will remind you to leave for soccer pickup at
    """#

    // MARK: - Charts, as the steward-cards skill's own examples write them

    static let weeklyChart = #"""
    The second week was the lightest.

    ```steward-card
    {"type":"chart","title":"Grocery spend","kind":"bar","x":["W1","W2","W3"],"series":[{"name":"Spend","values":[142,118,131]}],"unit":"$"}
    ```
    """#

    static let thermostatChart = #"""
    It warmed up through the afternoon and peaked at 72.5°F around 4 PM.

    ```steward-card
    {"type":"chart","title":"Thermostat today","kind":"line","x":["12 AM","2 AM","4 AM","6 AM","8 AM","10 AM","12 PM","2 PM","4 PM","6 PM","8 PM","10 PM"],"series":[{"name":"Living room","values":[68,67.5,67,67,69,70.5,71,72,72.5,71,70,69]}],"unit":"°F"}
    ```
    """#

    /// A whole day hour by hour, the most labels a chart takes.
    static let dayChart = #"""
    Coolest just before dawn, warmest late in the afternoon.

    ```steward-card
    {"type":"chart","title":"Living room, every hour","kind":"line","x":["12 AM","1 AM","2 AM","3 AM","4 AM","5 AM","6 AM","7 AM","8 AM","9 AM","10 AM","11 AM","12 PM","1 PM","2 PM","3 PM","4 PM","5 PM","6 PM","7 PM","8 PM","9 PM","10 PM","11 PM"],"series":[{"name":"Living room","values":[68,67.5,67,67,66.5,66.5,67,68.5,69.5,70,70.5,71,71.5,72,72,72.5,72.5,72,71.5,71,70.5,70,69.5,69]}],"unit":"°F"}
    ```
    """#

    static let pricesChart = #"""
    Pour-over is the cheapest by far.

    ```steward-card
    {"type":"chart","title":"Coffee makers","kind":"bar","x":["Drip","Pour-over","Espresso","Cold brew"],"series":[{"name":"Price","values":[39.99,24.5,189,59.95]}],"unit":"$"}
    ```
    """#

    static let scheduleChart = #"""
    Saturday is the busiest day.

    ```steward-card
    {"type":"chart","title":"Practice this week","kind":"bar","x":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"series":[{"name":"Soccer","values":[1.5,0,1.5,0,1.5,2,0]},{"name":"Piano","values":[0.5,0.5,0.5,0.5,0,1,0]}],"unit":"h"}
    ```
    """#

    static let monthsChart = #"""
    The kids went up the most since September.

    ```steward-card
    {"type":"chart","title":"Spending by category","kind":"bar","x":["Groceries","Dining","Gas","Kids"],"series":[{"name":"October","values":[284,146,92,120]},{"name":"September","values":[310,98,105,64]}],"unit":"$"}
    ```
    """#
}
#endif
