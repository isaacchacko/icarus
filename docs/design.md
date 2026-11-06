# design

icarus is a terminal app, so its brand is colour, glyphs and words, all drawn in nvim.

## colour

Every colour icarus draws is in `lua/icarus/theme.lua`, named for what it means. Add a colour there
before using it anywhere else.

- **sun** `#e5c07b`: the warm accent. Comments, nags, and what waits on you.
- **leaf** `#98c379`: done and open. Reader mode, open PRs, proposed additions.
- **sky** `#61afef`: agents and links.
- **violet** `#c678dd`: forks, merged PRs, icarus's own links.
- **ember** `#d19a66`: the router.
- **coral** `#e06c75`: auto mode, closed PRs, removals.
- **teal** `#56b6c2`: democracy, and your own comments.
- **mute** `#7f848e`: drafts, hints, anything without a state.
- **ash** `#abb2bf`: a task ready to start.
- **field**: the home screen's ramp from deep sky to warm sun. The brand's one gradient.

Why: the home field runs sky to sun, so the warm end is the accent and the name's story is the colour.
Why: the accents are one-dark's hues, so icarus reads as one thing beside any colourscheme.
Not: `acp/look.lua` keeps Claude Code's own palette on purpose, because chats mirror Claude Code.

## states

- A state is a colour and a word or glyph together, never colour alone.
- Badges are one word in capitals on a solid colour: `READER`, `AGENT`, `FORK`, `ROUTER`, `AUTO`.

## words

- Short, plain sentences. The fewest words that say what happened.
- No emoji in icarus's own UI. Glyphs are nerd-font or standard symbols.
- Labels name the thing: `task`, `agent`, `file`, not `item` or `entry`.
