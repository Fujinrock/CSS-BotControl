# CS:S Bot Control
SourceMod plugin for Counter-Strike: Source (v34) that lets you take control of bots upon dying like in CS:GO. Has been tested to work on CS:S v34 (build 4044) with SourceMod v1.8.0.5963. Other versions of CS:S and SourceMod are untested and may or may not work properly.

## How to build the plugin
The plugin requires [smlib](https://github.com/bcserv/smlib) in order to be built. No other external libraries are required. After installing smlib, it can be built like any other SourceMod plugin.

## How to use the plugin
Move "css_botcontrol.inc" to "addons/sourcemod/scripting/include" and "css_botcontrol.smx" to "addons/sourcemod/plugins".

To take control of a bot, press the USE key while spectating it in the first or third person camera mode. If you want to take control of an enemy player only for that specific round, hold the WALK button while you press USE, and you will be returned to your original team after the round is over.

## Console variables
The plugin has the following console variables for server operators:
|ConVar|Default value|Description|
|--------|-------|-------|
|botcontrol_allow_human_control|0|Whether to allow you to take control of other human players|
|botcontrol_always_one_round|0|Whether cross-team controlling should always be only for one round|
|botcontrol_any_team|0|Whether players can take control of players in the enemy team as well|
|botcontrol_auto_control|0|Whether humans should automatically take control of bots after dying|
|botcontrol_auto_control_closest|1|Whether the closest valid bot to your death location should be chosen by auto control|
|botcontrol_auto_control_delay|1.0|The delay in seconds after which the dead player will take control of a bot|
|botcontrol_auto_control_enemy|0|Whether auto control should give you control of an enemy (regardless of mp_forcecamera setting)|
|botcontrol_keep_controlled_weapons|0|Whether to keep the controlled player's weapons at the start of next round|
|botcontrol_keep_name|0|Whether the controller should play with their own name when taking control of another player|

The plugin will generate a config file for the plugin in "cstrike/cfg/sourcemod/css_botcontrol.cfg" the first time you run it.

## Known issues and missing features
- When taking control of a bot, the bot's position on the radar will be stuck at the position where you took control of it.
- When aiming at a player who is being controlled, the controller's name may be displayed unless mp_playerid is set to 2.
- There is no prompt for the user to take control of a bot they're spectating. This may be confusing for new players who are not familiar with the plugin.
- The amount of money returned back to the controller or the controlled player after a round ends might be inaccurate in some cases.
