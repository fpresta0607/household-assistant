---
name: steward-cards
# Kept under the 220 characters the skill catalog renders before it truncates,
# and front-loaded: this line is the whole routing signal the model sees.
description: "Steward app cards (channel=household): any chart or graph, tables, lists, events, reminders, maps, emails, texts, copy, products, cart, orders, scripture, sermons, sources, PocketPiggies, follow-ups. Never on Telegram."
metadata:
  {
    "openclaw":
      { "emoji": "🃏" },
  }
---

# Steward cards

The household's iPhone app, Steward AI, draws a card in place of a fenced block marked `steward-card`.
A card is one JSON object, and the app turns it into a native chart, table, checklist and so on, inside your reply.

## Only in the app

Send a card when the Runtime line of your system prompt says `channel=household`, which is the Steward AI app, or when a scheduled job explicitly delivers to the `household` channel.
An isolated scheduled run still needs cards when its delivery destination is Steward; use the job's actual destination, never an assumed one.
Anywhere else, Telegram included, answer in plain prose or an ordinary Markdown list, and never write a `steward-card` block.
Nothing turns a card into text on the way out, so on Telegram it would arrive as raw JSON.
A chart asked for on Telegram is the numbers as a short plain list.

## When to send one

In the app, send a card when the answer has a shape the family would otherwise have to read out of prose.

| the answer is | send |
|---|---|
| numbers someone asks to see as a chart or a graph, or numbers over time or side by side | `chart` |
| rows and columns | `table` (or an ordinary Markdown table, which the app also draws natively) |
| a list someone will tick off | `checklist` |
| something with a date and time | `event` |
| a day's or a week's plans at a glance, such as what is on today or this week | `agenda` |
| a reminder you set | `reminder` |
| where a place is, or how far someone is from it | `map` |
| a reminder for when someone gets somewhere or leaves it | `place-reminder` |
| an email someone asked about | `email` |
| a code, an address or a number to paste | `copy` |
| something to buy | `product` |
| a text your owner asked you to write to someone, or a reply to a text your owner got, in your owner's own thread only | `message` |
| the household cart, after `household_cart` changed it or someone asked to see it | `cart` |
| an Amazon order's progress, in your owner's own thread only | `order` |
| a Bible verse or passage | `scripture` |
| a sermon from the household's archive | `sermon` |
| an answer you found with a web search | `sources`, after the answer |
| a PocketPiggies balance, budget, spending or goal | `pocketpiggies` |
| something your owner is likely to ask you next | `followups`, at the very end, in your owner's own thread only |

One fact in a sentence needs no card, unless a skill found it: then the card is how the app shows which skill answered, so send the one that fits, such as the `event` the calendar gave you or the `sources` of a search.
Start with a short sentence that says what the card is, then the card.

Every PocketPiggies answer in the app is a `pocketpiggies` card, with a sentence before it.
PocketPiggies answers only in your owner's own thread with you, so never send one in the family room.

## The rules

- The opening line is three backticks and `steward-card`, nothing else, and the closing line is three backticks alone.
- One JSON object per block.
  Two cards are two blocks.
- Strict JSON: double quotes, no comments, no trailing commas.
- Numbers are JSON numbers, not strings, wherever the format below shows a number.
- Never put anything in a card that you did not get from a tool, a message or the family.
  A card looks authoritative, so a made-up figure in one is worse than in prose.
- A card the app cannot read is shown as its raw JSON, so check the field names against this page.

## The skill that answered

The app puts a small badge above your reply naming the skill that answered, and draws that reply in the skill's own look: parchment for scripture and sermons, PocketPiggies' rainbow, royal for the calendar, mint for lists and teal source chips for web search.
The badge comes from the first card in the reply that names a skill.

- `scripture`, `sermon`, `pocketpiggies` and `sources` cards name theirs on their own.
- Any other card names it with `"skill"`, one of `"scripture"`, `"sermons"`, `"pocketpiggies"`, `"calendar"`, `"lists"` or `"web"`, whenever a skill gave you what is in it: `"calendar"` on an `event` from the family calendar, `"lists"` on a `checklist` from a list or reminders you keep, `"pocketpiggies"` on a `chart` or `table` of PocketPiggies figures.
- Leave `"skill"` out of a card you made from the conversation alone.
  A reply without a skill wears no badge.

## Each card

### chart

Whenever someone asks for a chart, a graph or a plot, or to put something in a chart, answer with a chart card and never with prose instead: spending, a schedule, the thermostat over a day, a list of prices, any numbers at all.

- Use the numbers you already have from the conversation, a tool or a skill.
  If you have none yet, get them first from the tool or skill that has them.
  If nothing can give them, say in one sentence what is missing, and never make figures up.
- `kind` is `"line"` for one thing measured over time, such as a temperature through the day or a balance over months, and `"bar"` for amounts side by side, such as spending by category, prices or hours a day.
- `x` holds the labels, short, the way a person says them: `"6 AM"`, `"Mon"`, `"Oct 3"`, `"Milk"`.
  Up to 24 of them: for more points than that, keep every second or third, or add them up by day or by week.
- Every series has exactly one value for each label in `x`, a plain JSON number.
  Turn `"$4.99"` into `4.99`, `"72°F"` into `72` and `"1h 30m"` into `1.5`.
  Leave out a label that has no value rather than inventing one.
- Chart a schedule by how long things take, in hours or minutes, a day or an activity, never by the clock times themselves.
- Two to four series compare things over the same labels, such as this month and last, or the thermostat's setting and the room: give each a short `name`.
- `unit` is one for the whole chart, and optional: `"$"`, `"€"`, `"£"` and `"¥"` go before the number, `"%"`, `"°F"` and `"°C"` right after it, and anything else after a space, such as `"h"`, `"kWh"` or `"lb"`.
- `title` says what and when: `"Thermostat today"`, `"Grocery spend by week"`.
- One short sentence before the card says what it shows, or the one thing worth noticing in it.
  Do not list the numbers again after it.
- Never make a picture of a chart: the card is drawn on the phone, sharp at any size, in light and dark.
- Never use the dashboard tool for a chart or a table: its widgets reach nobody in the family, in the app or on Telegram.

```steward-card
{"type":"chart","title":"Grocery spend","kind":"bar","x":["W1","W2","W3"],"series":[{"name":"Spend","values":[142,118,131]}],"unit":"$"}
```

The thermostat through a day, from the readings a tool gave you:

```steward-card
{"type":"chart","title":"Thermostat today","kind":"line","x":["12 AM","2 AM","4 AM","6 AM","8 AM","10 AM","12 PM","2 PM","4 PM","6 PM","8 PM","10 PM"],"series":[{"name":"Living room","values":[68,67.5,67,67,69,70.5,71,72,72.5,71,70,69]}],"unit":"°F"}
```

A list of prices:

```steward-card
{"type":"chart","title":"Coffee makers","kind":"bar","x":["Drip","Pour-over","Espresso","Cold brew"],"series":[{"name":"Price","values":[39.99,24.5,189,59.95]}],"unit":"$"}
```

A schedule, by the hours each day takes:

```steward-card
{"type":"chart","title":"Practice this week","kind":"bar","x":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"series":[{"name":"Soccer","values":[1.5,0,1.5,0,1.5,2,0]},{"name":"Piano","values":[0.5,0.5,0.5,0.5,0,1,0]}],"unit":"h"}
```

This month beside last:

```steward-card
{"type":"chart","title":"Spending by category","kind":"bar","x":["Groceries","Dining","Gas","Kids"],"series":[{"name":"October","values":[284,146,92,120]},{"name":"September","values":[310,98,105,64]}],"unit":"$"}
```

### table

A cell is a string, a number or `null`.
`title` is optional.

```steward-card
{"type":"table","title":"This month","columns":["Store","Trips","Spend"],"rows":[["Corner market",5,"$171"],["Big box store",2,"$146"]]}
```

### checklist

`id` names the list, and it is how a tick finds its way back to you.
Make it short, lowercase and stable, such as `"shopping"` or `"before-trip"`, and send the same id every time you send that list again, with each item's `done` as it now stands.

```steward-card
{"type":"checklist","id":"before-trip","title":"Before the trip","items":[{"text":"Sign the permission slip","done":true},{"text":"Pack lunch","done":false}]}
```

When someone ticks an item in the app, the start of your next turn in that conversation carries a note like this:

> Franco ticked "Pack lunch" on the checklist "Before the trip" (id before-trip) in the app.

Take it as done.
If the same list lives somewhere else too, such as a reminder or the shopping list, bring that in step.

### event

`start` and `end` are ISO 8601 with the family's own offset, such as `"2026-10-16T20:00:00-04:00"`.
`end` and `location` are optional.
The app offers Add to Calendar, so send one whenever you name a plan with a time.

```steward-card
{"type":"event","title":"Movie night","start":"2026-10-16T20:00:00-04:00","end":"2026-10-16T22:00:00-04:00","location":"Living room"}
```

An event you read from the family calendar names it, and the app shows the day on a little calendar page:

```steward-card
{"type":"event","title":"Dentist, Gia","start":"2026-10-15T15:30:00-04:00","end":"2026-10-15T16:15:00-04:00","skill":"calendar"}
```

### agenda

A day, or up to a week, at a glance: the app draws each day as a little calendar page, the month in three letters over the day's number, beside one row for each thing, the thing in bold and its time.
Each day is `date`, YYYY-MM-DD, and its `events`, at most twelve, each a short `title` and its `time` as people say it, such as `"9:00 AM"`; leave `time` out for something all day.
`title` is optional; add `"skill":"calendar"` when the calendar gave you the plans.

```steward-card
{"type":"agenda","title":"This week","skill":"calendar","days":[{"date":"2026-10-26","events":[{"title":"Dentist","time":"9:00 AM"},{"title":"Piano lesson","time":"4:30 PM"}]},{"date":"2026-10-28","events":[{"title":"School picture day"}]}]}
```

### reminder

Only a reminder you actually set, with what it says and when it goes off, `at` in the same form as an event's `start`.

```steward-card
{"type":"reminder","text":"Leave for soccer pickup","at":"2026-10-17T17:30:00-04:00"}
```

### map

A small map of one place, which the app draws with Apple Maps on the phone.
`center` is the place and `label` names its pin.
`route` is optional, `"driving"` or `"walking"`, and asks the app to draw the way there from wherever the phone is, with how long it takes and when they would arrive.
Only coordinates a tool or the family gave you, such as a place you keep in memory or what `household_location` said, never a guess.
The app works out the way on the phone, so say a distance or a time in your words only when a tool gave it to you.

```steward-card
{"type":"map","center":{"latitude":39.7684,"longitude":-86.1581},"label":"Home","route":"driving"}
```

### place-reminder

A reminder that goes off when someone gets to a place or leaves it, such as "when I get home".
Nothing is set until the person taps Set on the card: their own iPhone then watches the place, even with the app closed, and the reminder goes off there.
You never hear when it does, so never say it is set, only that it is ready to set.

- `when` is `"arrive"` or `"leave"`.
- `place` has a `label`, its `latitude` and `longitude`, and an optional `radius` in metres, from 100 to 1000, 150 without one.
  Write `label` the way a person says the place after "at", such as `"home"`, `"work"` or `"Maple Elementary"`.
- `text` is what the reminder says.
- For your owner, in your owner's own thread, leave `for` out.

```steward-card
{"type":"place-reminder","text":"Take the trash out","place":{"label":"home","latitude":39.7684,"longitude":-86.1581},"when":"arrive"}
```

When it would watch somebody else, such as "tell me when Gia leaves work", only their own iPhone can watch them, and only after they say yes on the card.

- Send it in the family room, with `for` set to their name, and say in your owner's thread that you asked them.
- `text` says what you will do, such as `"Tell Franco"`.
- When their iPhone sees it happen, it replies to your card in the family room with what happened, such as "Left work.", and that reply starts your turn there: tell your owner, briefly, in the family room.
- If they say no, the card shows it, and you do nothing more.

```steward-card
{"type":"place-reminder","text":"Tell Franco","place":{"label":"work","latitude":39.7817,"longitude":-86.1478,"radius":200},"when":"leave","for":"Gia"}
```

### email

`to` is optional.
The app offers Reply and Copy, and Reply writes to the address in `from` when it has one, as in `Name <address>`.

```steward-card
{"type":"email","from":"Maple Elementary <office@maple.example>","to":["Gia","Franco"],"subject":"Field trip on Friday","body":"The bus leaves at 9:00 and is back by 3:00."}
```

### copy

For anything someone will paste: a gate code, an address, a tracking number.
`label` is optional.

```steward-card
{"type":"copy","label":"Gate code","text":"4821"}
```

### product

Only `name` is required.
`image` and `url` must be `https` links.

```steward-card
{"type":"product","name":"Insulated water bottle","price":"$24.99","store":"Sports Corner","image":"https://example.com/bottle.jpg","url":"https://example.com/bottle"}
```

### message

A text for your owner to send from his own iPhone, with who it is for and the words.
The app finds that person in his Contacts on the phone, lets him change the words, and opens Messages with both filled in, where nothing goes out until he taps send.
You never see his contacts, and you never need to: the phone matches the name.

- Only in your owner's own thread with you, never in the family room.
- Only when your owner asks you to text someone, says yes to a follow-up such as "Text Gia", or hands you a text to answer.
- `to` is the person as you know them, such as `"Gia"` or `"Mom"`, never a number or an address.
- Write the words as your owner would send them, in his voice, ready to go.
- Never say the text was sent: you cannot know, and only he decides.
  Say it is ready for him to send.

```steward-card
{"type":"message","to":"Gia","text":"Running 10 minutes late, start dinner without me."}
```

To send someone an event, such as "send Sarah the movie night", put the event on the message card as `event`, written as an `event` card is but without its `type`.
The app attaches it as a calendar file the person taps to add, so the words still say what, when and where.

```steward-card
{"type":"message","to":"Sarah","text":"Movie night Friday at 8 at our place. The invite is attached.","event":{"title":"Movie night","start":"2026-10-23T20:00:00-04:00","end":"2026-10-23T22:00:00-04:00","location":"Our place"}}
```

Your owner hands you a text they got in two ways: shared from another app, as a screenshot or its words, or sent by their iPhone in their name as a message that starts "A text from" and ends "Draft my reply."
Either way, read what the person wrote and draft the reply as a `message` card to them, by the name the text shows, after one short line on what they asked.
You cannot read their Messages or see anything they did not hand you, and you never send: the card is the reply, for your owner to send.

### cart

The household's one shared cart, which you and the other assistant both add to.
Send the `cart` that `household_cart` returned, exactly as it returned it, after every change to the cart and whenever someone asks what is in it, in your owner's own thread or the family room.
Its `id` is always `"household"`, so the app replaces the cart it showed before with the newer one.
`checkout` opens Amazon with every item that has an Amazon link, and the person adds them to their own Amazon cart and pays there.
An item without a link stays in the cart and out of `checkout`: say so when there is one.
Whoever checks out taps Ordered on the card, and the gateway takes those items out of the cart and posts the cart and the order itself, so you need not.

```steward-card
{"type":"cart","id":"household","title":"Household cart","items":[{"id":"ci-7f3a9c2e","name":"Paper towels, 12 rolls","quantity":1,"by":"Denise","for":"Gia","url":"https://www.amazon.com/dp/B07XYZ1234"},{"id":"ci-90ad3e44","name":"Birthday candles","quantity":1,"by":"Corey","for":"Franco"}],"checkout":"https://www.amazon.com/gp/aws/cart/add.html?ASIN.1=B07XYZ1234&Quantity.1=1","skill":"lists"}
```

### order

An Amazon order's progress, from your owner's own mail, or just Ordered when someone tapped it on the cart.
Send the `order` that `household_cart` returned for its `order` action, exactly as it returned it, in your owner's own thread only, and never in the family room.
`order` and `arriving` are there only when an email gave them.
When Amazon's own emails follow an order, the gateway posts each new step's order card in your owner's thread itself, so do not post it again.
The family room sees only that the items left the cart, and a sentence from you when they were delivered.

```steward-card
{"type":"order","title":"Household order","items":3,"status":"shipped","arriving":"2026-10-16","order":"113-***-4417","steps":[{"label":"Ordered","at":"2026-10-14T19:42:00-04:00"},{"label":"Shipped","at":"2026-10-15T06:10:00-04:00"},{"label":"Out for delivery"},{"label":"Delivered"}],"skill":"lists"}
```

### scripture

Only text the scripture skill returned, with its reference and translation exactly as it printed them, one entry per verse.
For daily sermons and devotionals, use the scripture skill's `ref "Book chapter:verse-range" --card` command and include its returned block unchanged before the teaching.
This applies equally to Corey and Denise and to scheduled deliveries into Steward. A Markdown quotation alone has no Open in Bible button.
Keep the commentary and prayer in prose; a newly written devotional is not an archive `sermon` card.
`link` opens the passage in the Bible app, in the edition the household reads: copy it from the scripture skill's `--card` block and never build it yourself. It has the form `https://www.bible.com/bible/<edition id>/<book>.<chapter>.<verses>.<edition>`, as in `https://www.bible.com/bible/111/JHN.3.16-17.NIV`.

```steward-card
{"type":"scripture","reference":"John 3:16-17","translation":"BSB","verses":[{"n":16,"text":"For God so loved the world that He gave His one and only Son, that everyone who believes in Him shall not perish but have eternal life."},{"n":17,"text":"For God did not send His Son into the world to condemn the world, but to save the world through Him."}],"link":"https://www.bible.com/bible/111/JHN.3.16-17.NIV","skill":"scripture"}
```

### sermon

Only a sermon the scripture skill's `sermons` command returned, with its title as it printed it.
`quote` is one line from it, in its own words, and `minutes` how long it runs, only when the sermon says.
`quote`, `minutes` and `link` are optional, and `link` must be an `https` page the family can open.

```steward-card
{"type":"sermon","title":"Love that gives","quote":"Love is not measured by what we keep, but by what we give away gladly.","minutes":12}
```

### sources

The pages a web search answer came from, after the answer, each as a chip that opens it.
Only pages you actually read, each an `https` link.
`title` is optional and short, such as the site's name, and without it the chip shows the site.

```steward-card
{"type":"sources","links":[{"url":"https://www.cityparks.example/pools/hours","title":"City parks"},{"url":"https://news.example/pool-reopens"}]}
```

### pocketpiggies

Only figures PocketPiggies gave you, in dollars: its reads name their money units, so turn cents into dollars.
Only in your owner's own thread with you in the app, never in the family room.
When the answer's `freshness` is more than an hour old, or its sync is still running, the sentence before the card says how fresh the figures are, such as "As of 9:40 this morning".
`card` is one of four:

```steward-card
{"type":"pocketpiggies","card":"balance","balance":1284.50,"piggies":[{"name":"Fun","balance":210},{"name":"Savings","balance":860}],"skill":"pocketpiggies"}
```

```steward-card
{"type":"pocketpiggies","card":"budget","month":"October","spent":640,"limit":900,"daysLeft":9,"skill":"pocketpiggies"}
```

```steward-card
{"type":"pocketpiggies","card":"spending","title":"Spending by category","categories":[{"name":"Groceries","amount":284},{"name":"Dining","amount":146}],"skill":"pocketpiggies"}
```

```steward-card
{"type":"pocketpiggies","card":"goal","name":"Beach trip","saved":680,"target":1000,"weekly":40,"skill":"pocketpiggies"}
```

`piggies`, `daysLeft`, `title` and `weekly` are optional.

### followups

Up to three short things your owner is likely to ask you next, which the app shows as chips under your reply rather than in it.
A tap sends the chip's words to you as your owner's next message, so write each one the way your owner would say it to you, in a few words: `"Remind me at 3:45"`, `"Text Gia"`, `"Add movie night"`.

- Only in your owner's own thread with you, never in the family room, where a tap would send the words to the whole family.
- Only when a next step is likely, such as a reminder, a message to someone or a calendar entry for what you just said, and never more than three.
- Each one must be something you can do or answer, and never something you already did in this reply.
- It goes at the very end of the reply, after everything else, and it needs no sentence before it.
- `icon` is optional, one of `"reminder"`, `"calendar"`, `"list"`, `"message"` or `"search"`, and without it the chip shows a sparkle.

```steward-card
{"type":"followups","items":[{"text":"Remind me at 3:45","icon":"reminder"},{"text":"Text Gia"},{"text":"Add movie night","icon":"calendar"}]}
```
