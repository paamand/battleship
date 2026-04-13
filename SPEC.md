Goal: Create a "battleship"-type game for iPad for two players on the same tablet written in Flutter.

Game objective: The player controls a battleship with the objective of eliminating the other players ship.

## Layout
The game screen is a shared split-screen with both players playing at the same time. The tablet is locked to portrait mode with player one playing at the normal orientation (bottom)and player two from the top-down mirrored.
The tablet screen game layout is so that bottom-half of screen is player one and top-half is player two. In the middle there is an info-area where left half is player one info: torpedo cooldown, mine-button and current control state. Right half is the same for player two, but upside down (so that player two is playing mirrored to player one). In the middle is the score (as part of the info-area).

The game is real-time (not turn based). The whole game is black and white and all graphics are cartoon/sketch-like.

A battleship consist of a front cannon, a mid-section and the aft engine. I.e. if it was on a grid it would be a 3x1 sized object.

## Controls
A player has the following controls, all explaied in more detail later:
  1. Drag on ship to move (see below)
  2. Tap on visible map to fire cannon
  3. Long-press on visible map to fire torpedo
  4. Tap on mine-button to deploy a mine.

## Moving the ship
A player can drag on his ship which indicates the intended direction and speed. A drag indirectly controls the ships acceleration. A ship has a max acceleration, and the point is to have some impedance to making turns and rapid changes in speed. Such that if the ship is moving east and the player drags the ship to north it will make a turn towards north in a curve. If the player drags west, the ship will brake and eventually move backwards etc.

## Firing the cannon
A player can tap on the map to shoot a missile. Only one missile can fly from the ship at a time so another missile can only be fired once the first has landed. A missile travels in air flying over ships and only hits on the tap-spot.

## Firing a torpedo
A player can long-press on the map to shoot a torpedo. A torpedo takes 10 seconds to load, so after firing it cannot be fired before this cooldown timer. Torpedoes hits anything it crosses and has no final destination. If it does not hit it just goes out of the world.

## Deploy mine
Press on the Mine button to deploy a mine just behind the ship. Your mines are visible to yourself but only visible to others if within radar-distance. A ship sailing into a mine explodes and sinks. A mine disappears after 30 seconds. Deploying a mine has a cooldown of 5 seconds before another mine can be deployed.

## Radar-distance
The ship has a radar. If a missile or torpedo becomes within a "radar-range" of your ship it becomes visible along with the trajectory. This may allow you to move a bit, but also shows the direction from where it was fired. An enemy mine within radar-distance is visible. Another ship within radar-range is also visible.

## Game mechanics
- If another ship gets hit (missile, torpedo or mine) the hit location becomes visible to all players.

- Your ship sinks if it is hits a mine or it is hit in the middle or if both front and aft gets hit.

- If the front is hit you cannot shoot the cannon anymore (missiles), but you can still shoot torpedos and lay mines. If the aft is hit your engine is gone and you cannot move. You then gradually slow down your speed.

- When you sink an opponent you get a point and the opponent respawns at a random location on the map outside visible radar-range of other ships.

- The battleship max speed exeeds the torpedos, but only slightly.

- A torpedo may seek a battleship but it has inertia so that it can be outmaneuvered.

