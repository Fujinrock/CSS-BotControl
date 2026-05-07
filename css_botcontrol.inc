#if defined _BOTCONTROL_included
 #endinput
#endif
#define _BOTCONTROL_included

/**
 * Gets the controller of the given player.
 *
 * @param client	Client index.
 * @return			Client index of the controller or 0 if client is not being controlled.
 */
native int BotControl_GetClientController(int client);