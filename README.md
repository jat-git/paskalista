# Paskalista

A grudge list addon for World of Warcraft: Forever.

- Keep your own list of players, each with a comment like "stole my loot".
- In a group, everyone's lists are combined and shared.
- Copy players from other members' lists into your own.
- Listed players get a skull marker, a tooltip note, and a warning when they join your group.

## Install

Unzip a release into `World of Warcraft/_forever_/Interface/AddOns/`, or clone the repo there:

```sh
cd "World of Warcraft/_forever_/Interface/AddOns"
git clone <repo-url> Paskalista
```

Update with `git pull`, then `/reload` in game.

## Usage

`/paska` (or `/grudge`) opens the window. Right-click a player and pick **Add to Paskalista...** to add them.

| Command | Action |
|---|---|
| `/paska add [comment]` | add your target |
| `/paska addname Name [comment]` | add by name |
| `/paska remove Name` | remove |
| `/paska list` / `group` | print your list / the combined list |
| `/paska announce [Name]` | announce listed players in group chat |
| `/paska import Name` / `all` | copy a member's list / everyone's lists |
| `/paska sync` | re-share lists with the group |
| `/paska markers` | toggle skull markers |
| `/paska auto` | toggle automatic announcements |

## License

Public domain ([The Unlicense](https://unlicense.org)).
