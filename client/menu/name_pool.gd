class_name NamePool

const NAMES: Array[String] = [
    "Wolf", "Falcon", "Bandit", "Rogue", "Viper", "Hawk", "Maverick",
    "Bear", "Ghost", "Striker", "Raven", "Cobra", "Shadow", "Vulcan",
    "Reaper", "Hunter", "Tiger", "Lynx", "Panther", "Jaguar", "Eagle",
    "Phantom", "Wraith", "Nomad", "Drifter", "Outlaw", "Saber", "Lance",
    "Forge", "Anvil", "Titan", "Atlas", "Orion", "Nova", "Comet",
    "Blaze", "Ember", "Frost", "Storm", "Surge", "Bolt", "Pulse",
    "Echo", "Static", "Riot", "Havoc", "Mayhem", "Ronin", "Shogun",
    "Vandal", "Pirate", "Corsair", "Crusader", "Templar", "Spartan",
    "Centurion", "Legion", "Marauder", "Brawler", "Boomer",
]

static func random_name() -> String:
    return NAMES[randi() % NAMES.size()]
