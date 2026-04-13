# Battleship!
A vibe-coded battle-ship inspired game to play 2-persons no wifi.

This is an experiment to hands-on create a playable game entirely vibe-coded using GPT 5.3 Codex.

# Prompt
Read the attached SPEC.md. Use flutter and the Flutter MCP to complete the entre coding task to produce a playable game.

# Adjustments (prompts after the game was created)

- The game screen is a shared split-screen with both players playing at the same time. The tablet is locked to portrait mode with player one playing at the normal orientation (bottom)and player two from the top-down mirrored.

- The tablet screen game layout is so that bottom-half of screen is player one and top-half is player two. In the middle there is an info-area where left half is player one info: torpedo cooldown, mine-button and current control state. Right half is the same for player two, but upside down (so that player two is playing mirrored to player one). In the middle is the score (as part of the info-area).

- Remove the long-press to deploy mine and instead add the mine botton. Press on the Mine button to deploy a mine just behind the ship. Your mines are visible to yourself but only visible to others if within radar-distance. A mine disappears after 30 seconds. Deploying a mine has a cooldown of 5 seconds before another mine can be deployed.

- No limit on number of topedos, but they have a cooldown of 10 seconds before it can be fired again. Show the cooldown in the info-area.

- If your ship collides with another ship, the two ships take damage at the hit section, i.e. front of one ship and the collision point section of the other.

- It seems the world of each player is full screen so that the grid and missiles of one player is shown also on the other players side of the tablet. Fix that so that on each players "screen" is only that half of the layout minus the info-area.

- Show the cooldown of mine and torpedo in the info area as a small progress bar. Remove the additional action info in the score area.

- The radar-range only applies to mines. Ships, missiles and torpedos are always visible.

- The direction to another ship is indicated as a red dot on the radar-range circle.

- The cooldown of missiles shall be 1 second. No rule about only one missile at a time.

- Show the cooldown of missiles together with the torpedos and mines in the info area
If a missile hits a mine, the mine is exploded and deleted.

- You can hit your own mines and explode.

