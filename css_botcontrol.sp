#pragma semicolon 1

#define DEBUG

#define PLUGIN_AUTHOR "Fujinrock"
#define PLUGIN_VERSION "2.0"

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include "smlib.inc"

#pragma newdecls required

bool g_bSwitchingTeams[MAXPLAYERS+1];
bool g_bSwitchingOneRound[MAXPLAYERS+1];
int g_nTakingControlOf[MAXPLAYERS+1];
int g_nControlTakenBy[MAXPLAYERS+1];
int g_nSwitchToWeapon[MAXPLAYERS+1];
int g_nSavedAccount[MAXPLAYERS+1];
int g_nRoundEndAccount[MAXPLAYERS+1];
int g_nPlayerLastTeam[MAXPLAYERS+1];
int g_nCopyButtons[MAXPLAYERS+1];
float g_flForwardVelocity[MAXPLAYERS+1];
float g_flLateralVelocity[MAXPLAYERS+1];
float g_flAutoControlTimestamp[MAXPLAYERS+1];
float g_flNextControlAttemptTime[MAXPLAYERS+1];
float g_flLastTeamDamageMsgTimestamp[MAXPLAYERS+1];
float g_vecLastDeathLocation[MAXPLAYERS+1][3];

int g_playerManager = -1;
int g_nLastController;

bool g_bRoundTerminated;
bool g_bWillRestart;
float g_flRoundTerminatedTimestamp;
float g_flLastControlTakenTimestamp;
float g_flRoundRestartDelay;

ConVar g_cvAllowHumanControl = null;
ConVar g_cvAllowAnyTeam = null;
ConVar g_cvAlwaysOneRound = null;
ConVar g_cvKeepControlledWeapons = null;
ConVar g_cvKeepName = null;
ConVar g_cvRestartGame = null;
ConVar g_cvAutoControlEnabled = null;
ConVar g_cvAutoControlDelay = null;
ConVar g_cvAutoControlTakeClosest = null;
ConVar g_cvAutoControlEnemy = null;
ConVar g_cvStartMoney = null;
ConVar g_cvFriendlyFire = null;

Handle g_hRoundEndTimer = INVALID_HANDLE;

public Plugin myinfo = 
{
	name = "Bot Control",
	author = PLUGIN_AUTHOR,
	description = "Take control of bots when dead",
	version = PLUGIN_VERSION,
	url = "https://github.com/Fujinrock/CSS-BotControl"
};

enum ControlResult
{
	CONTROL_OK = 0,
	CONTROL_SOLE_PLAYER,
	CONTROL_STUCK_RISK,
	CONTROL_UNDER_CONTROL,
	CONTROL_TAKING_CONTROL,
}

// =======================================================================================================================================================
//-----KNOWN ISSUES-----//
//BUG: Controlled bot's position stays in-place on radar
public void OnPluginStart()
{
	HookEvent("player_hurt", Event_PlayerHurt);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_team", Event_PlayerChangeTeam, EventHookMode_Pre);
	HookEvent("player_disconnect", Event_PlayerDisconnect);
	HookEvent("bomb_defused", Event_Bomb);
	HookEvent("bomb_exploded", Event_Bomb);
	AddNormalSoundHook(DeathSoundBlock);
	HookUserMessage(GetUserMessageId("TextMsg"), FriendlyFireWarning, true);
	
	g_cvAllowHumanControl = CreateConVar("botcontrol_allow_human_control", "0", "Whether to allow you to take control of other human players", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvAllowAnyTeam = CreateConVar("botcontrol_any_team", "0", "Whether players can take control of players in the enemy team as well", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvKeepControlledWeapons = CreateConVar("botcontrol_keep_controlled_weapons", "0", "Whether to keep the controlled player's weapons at the start of next round", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvKeepName = CreateConVar("botcontrol_keep_name", "0", "Whether the controller should play with their own name when taking control of another player", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvAutoControlEnabled = CreateConVar("botcontrol_auto_control", "0", "Whether humans should automatically take control of bots after dying", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvAutoControlDelay = CreateConVar("botcontrol_auto_control_delay", "1.0", "The delay in seconds after which the dead player will take control of a bot", _, true, 0.1);
	g_cvAutoControlTakeClosest = CreateConVar("botcontrol_auto_control_closest", "1", "Whether the closest valid bot to your death location should be chosen by auto control", _, true, 0.0, true, 1.0);
	g_cvAutoControlEnemy = CreateConVar("botcontrol_auto_control_enemy", "0", "Whether auto control should give you control of an enemy (regardless of mp_forcecamera setting)", _, true, 0.0, true, 1.0);
	g_cvAlwaysOneRound = CreateConVar("botcontrol_always_one_round", "0", "Whether cross-team controlling should always be only for one round", _, true, 0.0, true, 1.0);
	
	g_cvRestartGame = FindConVar("mp_restartgame");
	g_cvStartMoney = FindConVar("mp_startmoney");
	g_cvFriendlyFire = FindConVar("mp_friendlyfire");
	HookConVarChange(g_cvRestartGame, OnRestartGame);
	
	AutoExecConfig(true, "css_botcontrol");
}

// =======================================================================================================================================================

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("css_botcontrol");
	CreateNative("BotControl_GetClientController", GetClientController);
	
	return APLRes_Success;
}

// =======================================================================================================================================================

public void OnMapStart()
{
	for(int i = 0; i <= MaxClients; ++i)
	{
		g_flNextControlAttemptTime[i] = 0.0;
		g_flLastTeamDamageMsgTimestamp[i] = 0.0;
		g_flAutoControlTimestamp[i] = 0.0;
		g_bSwitchingOneRound[i] = false;
		g_bSwitchingTeams[i] = false;
		g_nTakingControlOf[i] = 0;
		g_nControlTakenBy[i] = 0;
		g_nSwitchToWeapon[i] = 0;
	}
	
	g_flLastControlTakenTimestamp = 0.0;
	g_bRoundTerminated = false;
	g_flRoundTerminatedTimestamp = 0.0;
	g_flRoundRestartDelay = 5.0;
	g_bWillRestart = false;
	
	g_playerManager = FindEntityByClassname(-1, "cs_player_manager");
	if(g_playerManager != -1)
		SDKHook(g_playerManager, SDKHook_ThinkPost, PlayerManagerOnThinkPost);
}

// =======================================================================================================================================================

public void OnMapEnd()
{
	if(g_playerManager != -1)
		SDKUnhook(g_playerManager, SDKHook_ThinkPost, PlayerManagerOnThinkPost);
}

// =======================================================================================================================================================

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if(IsFakeClient(client) || GetClientTeam(client) < CS_TEAM_T)
		return Plugin_Continue;
	
	if(g_nSwitchToWeapon[client])
	{
		int newWeap = g_nSwitchToWeapon[client];
		g_nSwitchToWeapon[client] = 0;
		if(IsValidEdict(newWeap) && IsValidEntity(newWeap) && GetEntPropEnt(newWeap, Prop_Send, "m_hOwnerEntity") == client)
		{
			weapon = newWeap;
			return Plugin_Changed;
		}
	}
	
	const float flCopyInputsDuration = 1.3;
	
	if(GetGameTime() - g_flAutoControlTimestamp[client] < flCopyInputsDuration)
	{
		if(buttons & IN_FORWARD || buttons & IN_BACK || buttons & IN_MOVELEFT || buttons & IN_MOVERIGHT)
		{
			g_flAutoControlTimestamp[client] = 0.0;
		}
		else
		{
			buttons = g_nCopyButtons[client];
			vel[0] = g_flForwardVelocity[client];
			vel[1] = g_flLateralVelocity[client];
		}
	}
	
	if(IsPlayerAlive(client) || !(buttons & IN_USE)) // Have to be pressing use to take control of bot
		return Plugin_Continue;
	
	float curtime = GetGameTime();
	
	if(curtime < g_flNextControlAttemptTime[client])
		return Plugin_Continue;
	
	g_flNextControlAttemptTime[client] = curtime + 0.3;
	
	const int OBSERVE_FIRST_PERSON = 3;
	const int OBSERVE_THIRD_PERSON = 4;
	
	int spectatingMode = GetEntProp(client, Prop_Send, "m_iObserverMode");
	
	if(spectatingMode != OBSERVE_FIRST_PERSON && spectatingMode != OBSERVE_THIRD_PERSON) // Can't take control if we're in free camera mode
		return Plugin_Continue;
	
	int spectating = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
	
	if(!IsValidClient(spectating) 
	||(!IsFakeClient(spectating) && !GetConVarBool(g_cvAllowHumanControl)) 
	|| IsClientSourceTV(spectating)
	|| !IsPlayerAlive(spectating) 
	|| GetClientTeam(spectating) < CS_TEAM_T 
	||(GetClientTeam(spectating) != GetClientTeam(client) && !GetConVarBool(g_cvAllowAnyTeam)))
		return Plugin_Continue;
	
	bool oneRound = (buttons & IN_SPEED) > 0; // Holding walk means we're switching teams only for this round
	ControlResult result = TakeBot(client, spectating, oneRound);
	RespondToControlAttempt(client, result);
	
	return Plugin_Continue;
}

// =======================================================================================================================================================

ControlResult TakeBot(int human, int bot, bool oneRound = false)
{
	// Check for risk of getting stuck
	if(DangerOfGettingStuck(bot))
		return CONTROL_STUCK_RISK;
	
	// Check if the player is already being controlled or controlling someone else
	if(g_nControlTakenBy[bot])
		return CONTROL_UNDER_CONTROL;
	if(g_nTakingControlOf[bot])
		return CONTROL_TAKING_CONTROL;
	
	// Check if we need to switch teams
	int humanTeam = GetClientTeam(human);
	int botTeam = GetClientTeam(bot);
	if(humanTeam != botTeam)
	{
		int humanTeamCount = Team_GetClientCount(humanTeam);
		if(humanTeamCount == 1) // Don't allow taking control if we're the only player in our team (it would end the match)
			return CONTROL_SOLE_PLAYER;
		
		g_bSwitchingTeams[human] = true;
		
		if(!g_bSwitchingOneRound[human])
		{
			g_bSwitchingOneRound[human] = oneRound || g_cvAlwaysOneRound.BoolValue;
			g_nPlayerLastTeam[human] = humanTeam;
		}
		
		CS_SwitchTeam(human, botTeam);
	}
	
	// For blocking sounds
	g_flLastControlTakenTimestamp = GetGameTime();
	g_nLastController = human;
	
	// Bot's position, orientation and velocity
	float pos[3], angles[3], vel[3];
	GetClientAbsOrigin(bot, pos);
	GetClientEyeAngles(bot, angles);
	vel[0] = GetEntPropFloat(bot, Prop_Send, "m_vecVelocity[0]");
	vel[1] = GetEntPropFloat(bot, Prop_Send, "m_vecVelocity[1]");
	vel[2] = GetEntPropFloat(bot, Prop_Send, "m_vecVelocity[2]");
	
	// Other bot's properties
	int health = GetClientHealth(bot);
	int armor = GetClientArmor(bot);
	int money = GetEntProp(bot, Prop_Send, "m_iAccount");
	int helmet = GetEntProp(bot, Prop_Send, "m_bHasHelmet");
	int defuser = GetEntProp(bot, Prop_Send, "m_bHasDefuser");
	int nvg = GetEntProp(bot, Prop_Send, "m_bHasNightVision");
	int nvgOn = GetEntProp(bot, Prop_Send, "m_bNightVisionOn");
	
	// Take bot's model
	char BotModel[PLATFORM_MAX_PATH];
	GetClientModel(bot, BotModel, sizeof(BotModel));
	DataPack ModelData = new DataPack();
	ModelData.WriteCell(human);
	ModelData.WriteString(BotModel);
	RequestFrame(Frame_ChangeSkin, ModelData);
	
	// Spawn us back in the game at the bot's position and set the bot's properties
	g_nSavedAccount[human] = GetEntProp(human, Prop_Send, "m_iAccount");
	g_nTakingControlOf[human] = bot;
	CS_RespawnPlayer(human);
	TeleportEntity(human, pos, angles, vel);
	SetEntityHealth(human, health);
	Client_SetArmor(human, armor);
	SetEntProp(human, Prop_Send, "m_iAccount", money);
	SetEntProp(human, Prop_Send, "m_bHasHelmet", helmet);
	SetEntProp(human, Prop_Send, "m_bHasDefuser", defuser);
	SetEntProp(human, Prop_Send, "m_bHasNightVision", nvg);
	SetEntProp(human, Prop_Send, "m_bNightVisionOn", nvg && nvgOn);
	
	// Weapon stuff
	char class[32];
	int activeWeapon = GetEntPropEnt(bot, Prop_Send, "m_hActiveWeapon");
	int weapons = GetEntPropArraySize(bot, Prop_Send, "m_hMyWeapons");
	for(int i = 0; i < weapons; ++i)
	{
		// Get rid of human's weapon in this slot too
		int curWeapon = GetEntPropEnt(human, Prop_Send, "m_hMyWeapons", i);
		if(IsValidEdict(curWeapon) && IsValidEntity(curWeapon))
		{
			CS_DropWeapon(human, curWeapon, false, true);
			AcceptEntityInput(curWeapon, "Kill");
		}
		
		curWeapon = GetEntPropEnt(bot, Prop_Send, "m_hMyWeapons", i);
		if(!IsValidEdict(curWeapon) || !IsValidEntity(curWeapon))
			continue;
		
		GetEdictClassname(curWeapon, class, sizeof(class));
		
		// Silencer status
		bool silencerWeapon = false;
		int silencerOn = 0;
		if(StrEqual(class, "weapon_usp") || StrEqual(class, "weapon_m4a1"))
		{
			silencerWeapon = true;
			silencerOn = GetEntProp(curWeapon, Prop_Send, "m_bSilencerOn");
		}
		
		// Give us the bot's weapon
		int newWeap = Client_GiveWeapon(human, class, false);
		
		if(newWeap == INVALID_ENT_REFERENCE)
			continue;
		
		if(curWeapon == activeWeapon)
		{	// Switch to bot's active weapon on next frame
			g_nSwitchToWeapon[human] = newWeap;
		}
		
		if(silencerWeapon)
			SetEntProp(newWeap, Prop_Send, "m_bSilencerOn", silencerOn);
		
		// Ammo stuff
		int clipAmmo = GetEntProp(curWeapon, Prop_Send, "m_iClip1");
		SetEntProp(newWeap, Prop_Send, "m_iClip1", clipAmmo);
		
		int ammoType = GetEntProp(curWeapon, Prop_Send, "m_iPrimaryAmmoType");
		if(ammoType != -1)
		{
			int reserveAmmo = GetEntProp(bot, Prop_Send, "m_iAmmo", 4, ammoType);
			SetEntProp(human, Prop_Send, "m_iAmmo", reserveAmmo, 4, ammoType);
		}
		
		// Finally, remove the bot's weapon
		CS_DropWeapon(bot, curWeapon, false, true);
		AcceptEntityInput(curWeapon, "Kill");
	}
	
	// Kill bot, preserve its stats, remove ragdoll etc.
	SetEntProp(bot, Prop_Send, "m_bHasDefuser", 0);
	Client_SetDeaths(bot, Client_GetDeaths(bot) - 1);
	Client_SetScore(bot, Client_GetScore(bot) + 1);
	g_nControlTakenBy[bot] = human;
	ForcePlayerSuicide(bot);
	RemovePlayerRagdoll(bot);
	
	// Give the bot our money temporarily here. This is because if at the start of next round everyone had very high money (near 16000), then the team reward won't be calculated right.
	// The bot will be given back its money (from the controller) at the start of next round or when the controller dies
	// The bad side of this is that if the controlled player respawns during the same round, they're not going to get their money
	SetEntProp(bot, Prop_Send, "m_iAccount", g_nSavedAccount[human]);
	
	return CONTROL_OK;
}

// =======================================================================================================================================================

void RemovePlayerRagdoll(int client)
{
	if(!IsValidClient(client))
		return;
	
	int ragdoll = GetEntPropEnt(client, Prop_Send, "m_hRagdoll");
	if(ragdoll != -1)
		AcceptEntityInput(ragdoll, "Kill");
}

// =======================================================================================================================================================

void RemovePlayerWeaponsAndItems(int client, bool moveC4)
{
	if(!IsValidClient(client))
		return;
	
	if(moveC4) // Don't care about C4 if the player doesn't have it
		moveC4 = GetPlayerWeaponSlot(client, CS_SLOT_C4) != -1;
	
	SetEntProp(client, Prop_Send, "m_bHasDefuser", 0); // Remove defuser, the so called "items"
	
	int weapons = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for(int w = 0; w < weapons; ++w)
	{
		int curWeapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", w);
		if(IsValidEdict(curWeapon) && IsValidEntity(curWeapon))
		{
			CS_DropWeapon(client, curWeapon, false, true);
			AcceptEntityInput(curWeapon, "Kill");
		}
	}
	
	if(!moveC4)
		return;
	
	// Give a random terrorist the C4 that was removed from us
	int terrorists[MAXPLAYERS / 2];
	int found = 0;
	for(int i = 1; i <= MaxClients; ++i)
	{
		if(i != client && IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == CS_TEAM_T)
		{
			terrorists[found++] = i;
		}
	}
	
	if(found) // There's at least one suitable terrorist to give the bomb to
	{
		Client_GiveWeapon(terrorists[GetRandomInt(0, found - 1)], "weapon_c4", false);
	}
}

// =======================================================================================================================================================

public bool StuckFilter(int entity, int contentsMask, any data)
{
	return entity != data;
}

// =======================================================================================================================================================

bool DangerOfGettingStuck(int bot)
{
	float startPos[3];
	GetClientAbsOrigin(bot, startPos);
	
	startPos[2] += 18.0;
	
	float endPos[3];
	endPos[0] = startPos[0];
	endPos[1] = startPos[1];
	endPos[2] = startPos[2] + 45.0; // End the hull at standing height head position
	
	float mins[] = {-16.0, -16.0, 0.0};
	float maxs[] = {16.0, 16.0, 0.0};
	
	TR_TraceHullFilter(startPos, endPos, mins, maxs, MASK_PLAYERSOLID, StuckFilter, bot);
	
	return TR_DidHit();
}

// =======================================================================================================================================================

void Frame_ChangeSkin(DataPack data)
{
	data.Reset();
	int client = data.ReadCell();
	char BotModel[PLATFORM_MAX_PATH];
	data.ReadString(BotModel, sizeof(BotModel));
	CloseHandle(data);
	
	if(!IsValidClient(client))
		return;
	
	SetEntityModel(client, BotModel);
}

// =======================================================================================================================================================

public void Event_PlayerHurt(Event event, const char[] name, bool dBs)
{
	if(!GetConVarBool(g_cvFriendlyFire))
		return;
	
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	
	if(!IsValidClient(attacker) || victim == attacker)
		return;
	
	float flCurTime = GetGameTime();
	
	int team = GetClientTeam(victim);
	
	if(team != GetClientTeam(attacker))
		return;
	
	if(flCurTime - g_flLastTeamDamageMsgTimestamp[attacker] < 0.6)
		return;
	
	g_flLastTeamDamageMsgTimestamp[attacker] = flCurTime;
	
	char msg[80];
	if(g_nTakingControlOf[attacker] && IsValidClient(g_nTakingControlOf[attacker]))
	{
		GetClientName(g_nTakingControlOf[attacker], msg, sizeof(msg));
	}
	else
	{
		GetClientName(attacker, msg, sizeof(msg));
	}
	
	Format(msg, sizeof(msg), "%s attacked a teammate", msg);
	
	for(int i = 1; i <= MaxClients; ++i)
	{
		if(IsClientInGame(i) && GetClientTeam(i) == team)
		{
			PrintToChat(i, msg);
		}
	}
}

// =======================================================================================================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dBs)
{
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	
	if(g_bSwitchingTeams[victim]) // Switching back after one round control
	{
		Client_SetDeaths(victim, Client_GetDeaths(victim) - 1);
		Client_SetScore(victim, Client_GetScore(victim) + 1);
		return Plugin_Stop;
	}
	
	bool eventModified = false;
	if(g_nTakingControlOf[victim] > 0 && IsValidClient(g_nTakingControlOf[victim]) && GetClientTeam(g_nTakingControlOf[victim]) == GetClientTeam(victim))
	{
		Client_SetDeaths(victim, Client_GetDeaths(victim) - 1);
		Client_SetDeaths(g_nTakingControlOf[victim], Client_GetDeaths(g_nTakingControlOf[victim]) + 1);
		
		if(!attacker) // Suicide by world
		{
			Client_SetScore(victim, Client_GetScore(victim) + 1);
			Client_SetScore(g_nTakingControlOf[victim], Client_GetScore(g_nTakingControlOf[victim]) - 1);
		}
		
		if(!GetConVarBool(g_cvKeepName))
		{
			event.SetInt("userid", GetClientUserId(g_nTakingControlOf[victim]));
			eventModified = true;
		}
	}
	if(g_nTakingControlOf[attacker] > 0 && IsValidClient(g_nTakingControlOf[attacker]) && GetClientTeam(g_nTakingControlOf[attacker]) == GetClientTeam(attacker))
	{
		bool minusPoints = (victim == attacker || GetClientTeam(victim) == GetClientTeam(attacker)); // Take away points if death was a suicide or a teamkill
		Client_SetScore(attacker, Client_GetScore(attacker) - (minusPoints? -1 : 1));
		Client_SetScore(g_nTakingControlOf[attacker], Client_GetScore(g_nTakingControlOf[attacker]) + (minusPoints? -1 : 1));
		
		if(!GetConVarBool(g_cvKeepName))
		{
			event.SetInt("attacker", GetClientUserId(g_nTakingControlOf[attacker]));
			eventModified = true;
		}
	}
	
	if(g_nTakingControlOf[victim] > 0)
	{
		if(IsValidClient(g_nTakingControlOf[victim]) && GetClientTeam(g_nTakingControlOf[victim]) == GetClientTeam(victim))
			SetEntProp(g_nTakingControlOf[victim], Prop_Send, "m_iAccount", GetEntProp(victim, Prop_Send, "m_iAccount")); // Give the controlled player "our" money when we die
		
		SetEntProp(victim, Prop_Send, "m_iAccount", g_nSavedAccount[victim]); // Reset our money back to our saved account
		g_nControlTakenBy[g_nTakingControlOf[victim]] = 0;
		g_nTakingControlOf[victim] = 0;
	}
	
	if(GetConVarBool(g_cvAutoControlEnabled) && !IsFakeClient(victim))
	{
		GetClientEyePosition(victim, g_vecLastDeathLocation[victim]);
		CreateTimer(g_cvAutoControlDelay.FloatValue, Timer_BotAutoControl, victim, TIMER_FLAG_NO_MAPCHANGE);
	}
	
	if(eventModified)
	{
		return Plugin_Changed;
	}
	
	if(g_nControlTakenBy[victim])
	{
		return Plugin_Stop; // Or Plugin_Handled? Not sure
	}
	
	return Plugin_Continue;
}

// =======================================================================================================================================================

public void Event_RoundStart(Event event, const char[] name, bool dBs)
{
	g_bWillRestart = false;
	int CTReward = 0, TReward = 0;
	
	int startMoney = g_cvStartMoney.IntValue;
	bool isFirstRound = startMoney < 16000; // We only care about first round if everyone is not starting with full money
	
	if(g_bRoundTerminated) // Get our best guess about how much each team earned money this at this round's start
	{
		for(int i = 1; i <= MaxClients; ++i)
		{
			if(!IsClientConnected(i) || !IsClientInGame(i))
				continue;
			
			int team = GetClientTeam(i);
			
			if(team < CS_TEAM_T)
				continue;
			
			int money = GetEntProp(i, Prop_Send, "m_iAccount");
			
			if(money != startMoney)
				isFirstRound = false;
			
			int teamReward = money - g_nRoundEndAccount[i];
			
			switch(team)
			{
				case CS_TEAM_T:
				{
					if(teamReward > TReward)
						TReward = teamReward;
				}
				case CS_TEAM_CT:
				{
					if(teamReward > CTReward)
						CTReward = teamReward;
				}
			}
		}
	}
	
	for(int i = 1; i <= MaxClients; ++i)
	{
		g_nControlTakenBy[i] = 0;
		
		if(g_nTakingControlOf[i] && !isFirstRound && !GetConVarBool(g_cvKeepControlledWeapons)) // Swap the weapons of controller and controlled players
		{
			int controlled = g_nTakingControlOf[i];
			
			if(!IsValidClient(i) || !IsValidClient(controlled))
				continue;
			
			if(GetClientTeam(i) < CS_TEAM_T || GetClientTeam(i) != GetClientTeam(controlled))
				continue;
			
			if(!IsPlayerAlive(i) || !IsPlayerAlive(controlled))
				continue;
			
			int armor = GetClientArmor(i);
			int helmet = GetEntProp(i, Prop_Send, "m_bHasHelmet");
			int defuser = GetEntProp(i, Prop_Send, "m_bHasDefuser");
			int nvg = GetEntProp(i, Prop_Send, "m_bHasNightVision");
			int nvgOn = GetEntProp(i, Prop_Send, "m_bNightVisionOn");
			
			if(g_bRoundTerminated) // Round ended normally (not restarted)
			{
				int money = GetEntProp(i, Prop_Send, "m_iAccount");
				int teamReward = GetClientTeam(i) == CS_TEAM_T? TReward : CTReward;
				
				int controllerTotalMoney = g_nSavedAccount[i] + teamReward;
				if(controllerTotalMoney > 16000)
					controllerTotalMoney = 16000;
				
				SetEntProp(controlled, Prop_Send, "m_iAccount", money);
				SetEntProp(i, Prop_Send, "m_iAccount", controllerTotalMoney);
			}
			
			// Give controlled the controller's properties
			Client_SetArmor(controlled, armor);
			SetEntProp(controlled, Prop_Send, "m_bHasHelmet", helmet);
			SetEntProp(controlled, Prop_Send, "m_bHasDefuser", defuser);
			SetEntProp(controlled, Prop_Send, "m_bHasNightVision", nvg);
			SetEntProp(controlled, Prop_Send, "m_bNightVisionOn", nvg && nvgOn);
			
			// Remove controller's paid properties
			Client_SetArmor(i, 0);
			SetEntProp(i, Prop_Send, "m_bHasHelmet", 0);
			SetEntProp(i, Prop_Send, "m_bHasDefuser", 0);
			SetEntProp(i, Prop_Send, "m_bHasNightVision", 0);
			SetEntProp(i, Prop_Send, "m_bNightVisionOn", 0);
			
			// Swap weapons here
			char class[32];
			int activeWeapon = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
			int weapons = GetEntPropArraySize(i, Prop_Send, "m_hMyWeapons");
			for(int w = 0; w < weapons; ++w)
			{
				// First remove the controlled's weapons
				int curWeapon = GetEntPropEnt(controlled, Prop_Send, "m_hMyWeapons", w);
				if(IsValidEdict(curWeapon) && IsValidEntity(curWeapon))
				{
					GetEdictClassname(curWeapon, class, sizeof(class));
					
					if(!StrEqual(class, "weapon_c4") && !StrEqual(class, "weapon_knife")) // Don't swap C4 or knife
					{
						CS_DropWeapon(controlled, curWeapon, false, true);
						AcceptEntityInput(curWeapon, "Kill");
					}
				}
				
				curWeapon = GetEntPropEnt(i, Prop_Send, "m_hMyWeapons", w);
				if(!IsValidEdict(curWeapon) || !IsValidEntity(curWeapon))
					continue;
				
				GetEdictClassname(curWeapon, class, sizeof(class));
				
				if(StrEqual(class, "weapon_c4") || StrEqual(class, "weapon_knife")) // Don't swap C4 or knife
					continue;
				
				// Silencer status
				bool silencerWeapon = false;
				int silencerOn = 0;
				if(StrEqual(class, "weapon_usp") || StrEqual(class, "weapon_m4a1"))
				{
					silencerWeapon = true;
					silencerOn = GetEntProp(curWeapon, Prop_Send, "m_bSilencerOn");
				}
				
				// Give the controlled the controller's weapon
				int newWeap = Client_GiveWeapon(controlled, class, false);
				
				if(newWeap == INVALID_ENT_REFERENCE)
					continue;
				
				if(curWeapon == activeWeapon)
				{	// Switch to the active weapon on next frame
					g_nSwitchToWeapon[controlled] = newWeap;
				}
				
				if(silencerWeapon)
					SetEntProp(newWeap, Prop_Send, "m_bSilencerOn", silencerOn);
				
				// Ammo stuff
				int clipAmmo = GetEntProp(curWeapon, Prop_Send, "m_iClip1");
				SetEntProp(newWeap, Prop_Send, "m_iClip1", clipAmmo);
				
				int ammoType = GetEntProp(curWeapon, Prop_Send, "m_iPrimaryAmmoType");
				if(ammoType != -1)
				{
					int reserveAmmo = GetEntProp(i, Prop_Send, "m_iAmmo", 4, ammoType);
					SetEntProp(controlled, Prop_Send, "m_iAmmo", reserveAmmo, 4, ammoType);
				}
				
				// Finally, remove the controller's weapon
				CS_DropWeapon(i, curWeapon, false, true);
				AcceptEntityInput(curWeapon, "Kill");
			}
			// Give the controller back their default pistol with default ammo
			bool isGlock = (GetClientTeam(i) == CS_TEAM_T);
			int pistol = Client_GiveWeapon(i, isGlock? "weapon_glock":"weapon_usp", false);
			g_nSwitchToWeapon[i] = pistol;
			int ammoType = GetEntProp(pistol, Prop_Send, "m_iPrimaryAmmoType");
			SetEntProp(i, Prop_Send, "m_iAmmo", isGlock? 120:100, 4, ammoType);
		}
		if(g_bSwitchingOneRound[i])
		{
			g_bSwitchingOneRound[i] = false;
			
			if(GetClientTeam(i) != g_nPlayerLastTeam[i])
			{
				g_bSwitchingTeams[i] = true;
				RemovePlayerWeaponsAndItems(i, true);
				ForcePlayerSuicide(i);
				RemovePlayerRagdoll(i);
				CS_SwitchTeam(i, g_nPlayerLastTeam[i]);
				CS_RespawnPlayer(i);
				
				if(isFirstRound)
					SetEntProp(i, Prop_Send, "m_iAccount", startMoney);
				else
				{
					int teamReward = g_nPlayerLastTeam[i] == CS_TEAM_T? TReward : CTReward;
					
					int totalMoney = g_nSavedAccount[i] + teamReward;
					if(totalMoney > 16000)
						totalMoney = 16000;
					SetEntProp(i, Prop_Send, "m_iAccount", totalMoney);
				}
			}
		}
		
		g_nTakingControlOf[i] = 0;
	}
	g_bRoundTerminated = false;
}

// =======================================================================================================================================================

public Action CS_OnTerminateRound(float &delay, CSRoundEndReason &reason)
{
	g_flRoundRestartDelay = delay;
	g_bRoundTerminated = !g_bWillRestart; // The round does not end normally if the game will be restarted
	g_flRoundTerminatedTimestamp = GetGameTime();
	
	if(g_hRoundEndTimer == INVALID_HANDLE && g_bRoundTerminated)
	{
		// Not a fancy solution, but without a detour it's the best I can think of
		g_hRoundEndTimer = CreateTimer(delay - 0.05, Timer_SavePlayerMoney, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

// =======================================================================================================================================================

public Action Timer_SavePlayerMoney(Handle timer)
{
	for(int i = 1; i <= MaxClients; ++i)
	{
		if(IsClientConnected(i) && IsClientInGame(i) && !IsClientSourceTV(i))
		{
			g_nRoundEndAccount[i] = GetEntProp(i, Prop_Send, "m_iAccount");
		}
	}
	
	g_hRoundEndTimer = INVALID_HANDLE;
	return Plugin_Stop;
}

// =======================================================================================================================================================

public Action Timer_BotAutoControl(Handle timer, int client)
{
	if(g_bRoundTerminated || !IsValidClient(client) || IsFakeClient(client) || IsPlayerAlive(client) || GetClientTeam(client) < CS_TEAM_T)
	{
		return Plugin_Stop;
	}
	
	int team = GetClientTeam(client);
	
	if(GetConVarBool(g_cvAutoControlEnemy))
	{
		if(g_bSwitchingOneRound[client])
			team = g_nPlayerLastTeam[client];
		
		team = (team == CS_TEAM_T)? CS_TEAM_CT : CS_TEAM_T;
	}
	
	int aliveInTeam = 0;
	
	int closest = 0;
	float closestDist = 999999999.9;
	
	for(int i = 1; i <= MaxClients; ++i)
	{
		if(IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == team && IsFakeClient(i))
		{
			++aliveInTeam;
			
			if(DangerOfGettingStuck(i))
				continue;
			
			if(GetEntProp(i, Prop_Send, "m_bIsDefusing"))
				continue;
			
			float botPos[3];
			GetClientEyePosition(i, botPos);
			bool valid = true;
			
			// Check enemy humans' visibility to this bot
			for(int e = 1; e <= MaxClients; ++e)
			{
				if(IsClientInGame(e) && IsPlayerAlive(e) && !IsFakeClient(e) && GetClientTeam(e) != team && GetClientTeam(e) >= CS_TEAM_T)
				{
					if(Client_CanSeePosition(e, botPos))
					{
						valid = false;
						break;
					}
				}
			}
			
			if(valid) // This bot is suitable for taking control, check if they're also the closest to the death location
			{
				if(GetConVarBool(g_cvAutoControlTakeClosest))
				{
					float dist = GetVectorDistance(g_vecLastDeathLocation[client], botPos, true);
					if(dist < closestDist)
					{
						closestDist = dist;
						closest = i;
					}
				}
				else // Take control of first suitable bot we find
				{
					TakeBot(client, i);
					return Plugin_Stop;
				}
			}
		}
	}
	
	if(closest)
	{
		TakeBot(client, closest);
		
		g_nCopyButtons[client] = GetClientButtons(closest);
		
		if(g_nCopyButtons[client] & IN_FORWARD)
			g_flForwardVelocity[client] = 300.0;
		else if(g_nCopyButtons[client] & IN_BACK)
			g_flForwardVelocity[client] = -300.0;
		else
			g_flForwardVelocity[client] = 0.0;
			
		if(g_nCopyButtons[client] & IN_LEFT)
			g_flLateralVelocity[client] = -300.0;
		else if(g_nCopyButtons[client] & IN_RIGHT)
			g_flLateralVelocity[client] = 300.0;
		else
			g_flLateralVelocity[client] = 0.0;
		
		g_flAutoControlTimestamp[client] = GetGameTime();
		
		return Plugin_Stop;
	}
	
	if(aliveInTeam)
		PrintToChat(client, "\x04[Bot Control] \x01A suitable bot for auto control was not found");
	
	return Plugin_Stop;
}

// =======================================================================================================================================================

public void Event_PlayerSpawn(Event event, const char[] name, bool dBs)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	g_nControlTakenBy[client] = 0;
}

// =======================================================================================================================================================

public Action Event_PlayerChangeTeam(Event event, const char[] name, bool dBs)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	if(g_bSwitchingOneRound[client] && event.GetInt("team") < CS_TEAM_T)
	{	// Don't put us back in our old team next round if we want to spectate
		g_bSwitchingOneRound[client] = false;
	}
	
	if(g_bSwitchingTeams[client])
	{
		g_bSwitchingTeams[client] = false;
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

// =======================================================================================================================================================

public void Event_PlayerDisconnect(Event event, const char[] name, bool dBs)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	// Remove control both ways
	if(g_nControlTakenBy[client])
	{
		g_nTakingControlOf[g_nControlTakenBy[client]] = 0;
		g_nControlTakenBy[client] = 0;
	}
	if(g_nTakingControlOf[client])
	{
		g_nControlTakenBy[g_nTakingControlOf[client]] = 0;
		g_nTakingControlOf[client] = 0;
	}
}

// =======================================================================================================================================================

public void Event_Bomb(Event event, const char[] name, bool dBs)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	if(client == -1)
		return;
	
	if(g_nTakingControlOf[client])
	{
		Client_SetScore(client, Client_GetScore(client) - 3);
		
		if(IsValidClient(g_nTakingControlOf[client]))
		{
			Client_SetScore(g_nTakingControlOf[client], Client_GetScore(g_nTakingControlOf[client]) + 3);
		}
	}
}

// =======================================================================================================================================================

public Action DeathSoundBlock(int clients[MAXPLAYERS], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	bool isClient = IsValidClient(entity);
	// Block sounds from taking a bot (death sounds, knife deploy, flashlight, and some others)
	if(GetGameTime() - g_flLastControlTakenTimestamp < 0.1)
	{
		if(isClient && (g_nControlTakenBy[entity] || entity == g_nLastController))
		{
			return Plugin_Stop;
		}
		if(StrContains(sample, "weapons/knife/knife_deploy1") == 0) // Knife sound comes from the weapon, not from the players
		{
			return Plugin_Stop;
		}
	}
	else if(isClient && g_bSwitchingTeams[entity])
		return Plugin_Stop;
	
	return Plugin_Continue;
}

// =======================================================================================================================================================

public Action FriendlyFireWarning(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	char buffer[128];
	BfReadString(msg, buffer, sizeof(buffer));
	
	if(StrContains(buffer, "Game_teammate_attack") != -1)
	{
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

// =======================================================================================================================================================

#define DEAD 0
#define ALIVE 1

public void PlayerManagerOnThinkPost(int manager)
{
	for(int i = 1; i <= MaxClients; ++i)
	{
		if(!IsClientInGame(i))
			continue;
		
		if(g_nTakingControlOf[i] && IsValidClient(g_nTakingControlOf[i]))
		{
			SetEntProp(manager, Prop_Send, "m_bAlive", DEAD, 4, i);
			SetEntProp(manager, Prop_Send, "m_bAlive", ALIVE, 4, g_nTakingControlOf[i]);
			
			if(GetPlayerWeaponSlot(i, CS_SLOT_C4) != -1) // Set the bomb correctly on scoreboard, too
			{
				SetEntProp(manager, Prop_Send, "m_iPlayerC4", g_nTakingControlOf[i]);
			}
		}
		if(g_bSwitchingOneRound[i])
		{
			SetEntProp(manager, Prop_Send, "m_iTeam", g_nPlayerLastTeam[i], 4, i);
		}
	}
}

// =======================================================================================================================================================

public void OnRestartGame(ConVar convar, const char[] oldValue, const char[] newValue)
{
	float delay = convar.FloatValue;
	
	if(delay <= 0)
		return;
	
	g_bWillRestart = true;
	
	if(g_bRoundTerminated) // Game is being restarted after round end
	{
		float roundTimeLeft = g_flRoundRestartDelay - (GetGameTime() - g_flRoundTerminatedTimestamp);
		
		if(delay < roundTimeLeft) // If the restart will happen before the round ends normally, kill the money saver timer
		{
			if(g_hRoundEndTimer != INVALID_HANDLE)
			{
				CloseHandle(g_hRoundEndTimer);
				g_hRoundEndTimer = INVALID_HANDLE;
			}
		}
	}
	
	g_bRoundTerminated = false; // Disable next round's money mechanisms
}

// =======================================================================================================================================================

void RespondToControlAttempt(int client, ControlResult result)
{
	switch(result)
	{
		case CONTROL_SOLE_PLAYER:
		{
			PrintToChat(client, "\x04[Bot Control] \x01Cannot take control of an enemy as the only player in your team");
		}
		case CONTROL_STUCK_RISK:
		{
			PrintToChat(client, "\x04[Bot Control] \x01Cannot take control due to risk of getting stuck");
		}
		case CONTROL_UNDER_CONTROL: // This should be impossible, as a player that's being controlled should be dead, so if you see this, there is a bug!
		{
			PrintToChat(client, "\x04[Bot Control] \x01Cannot take control because player is already being controlled");
		}
		case CONTROL_TAKING_CONTROL:
		{
			PrintToChat(client, "\x04[Bot Control] \x01Cannot take control of a player already controlling another player");
		}
	}
}

// =======================================================================================================================================================

public int GetClientController(Handle plugin, int numParams)
{
	if(g_cvKeepName.BoolValue) // There is no controller if the controller is playing as themself
		return 0;
	
	int client = GetNativeCell(1);
	if(IsValidClient(client) && g_nControlTakenBy[client])
	{
		if(IsValidClient(g_nControlTakenBy[client]))
			return g_nControlTakenBy[client];
	}
	return 0;
}

// =======================================================================================================================================================

bool IsValidClient(int client)
{
	if(client <= 0 || client > MaxClients || !IsClientInGame(client))
		return false;
	
	return true;
}

// =======================================================================================================================================================

bool Client_CanSeePosition(int client, const float vecPos[3])
{
	float vecClientPos[3];
	GetClientEyePosition(client, vecClientPos);
	
	TR_TraceRay(vecClientPos, vecPos, MASK_VISIBLE_AND_NPCS, RayType_EndPoint);
	
	return !TR_DidHit();
}

// =======================================================================================================================================================