/*
UTComp - UT2004 Mutator
Copyright (C) 2004-2005 Aaron Everitt & Joel Moffatt

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
*/
class NewNet_PRI extends LinkedReplicationInfo;

var float PredictedPing;
var float PingSendTime;
var bool bPingReceived;
var int numPings;
var UTComp_ServerReplicationInfo RepInfo;

var float PingTweenTime;

// Sliding window ping measurement
const PING_WINDOW_SIZE = 5;
var float MaxPing;                 // configurable cap (seconds), pulled from RepInfo
var float PingWindow[5];           // circular buffer of recent RTT samples
var int PingWindowIdx;             // next write position
var int PingWindowCount;           // how many valid samples we have (0..5)

// Server-measured round trip (server -> owning client -> server), the trusted
// bound on how far back a shot from this player may rewind (MutUTComp.RewindFor).
// The rewind itself comes from the stamp the client echoes, which a modified
// client can pick; a client can only RAISE this number by really answering late.
const SRV_PING_PERIOD = 0.5;       // seconds between server pings
const SRV_PING_TIMEOUT = 1.0;      // no answer by then: send a new one
var float SrvPingSentTime;
var byte SrvPingSeq;
var bool bSrvPingOut;
var float SrvRTTWindow[5];
var int SrvRTTIdx;
var int SrvRTTCount;
var float ServerRTT;               // median of the last 5 (server only)

replication
{
    reliable if(Role<Role_Authority)
        Ping;
    reliable if(Role == Role_Authority && bNetOwner)
        Pong;
    // Unreliable on purpose: a lost one is just resent, and a reliable one
    // would wait behind retransmits and measure the backlog, not the link.
    unreliable if(Role == Role_Authority && bNetOwner)
        ClientSrvPing;
    unreliable if(Role < Role_Authority)
        ServerSrvPong;
}

simulated function PostBeginPlay()
{
    local int i;

    super.PostBeginPlay();

    if(RepInfo == None)
        ForEach DynamicActors(class'UTComp_ServerReplicationInfo', RepInfo)
            break;

    if(RepInfo != none)
    {
        if(RepInfo.NewNetUpdateFrequency > 0)
        {
            NetUpdateFrequency=RepInfo.NewNetUpdateFrequency;
        }

        if(RepInfo.PingTweenTime > 0)
        {
            PingTweenTime=RepInfo.PingTweenTime;
        }

        if(RepInfo.MaxPing > 0)
        {
            MaxPing=RepInfo.MaxPing;
        }
    }

    // Initialize window to zero
    for(i = 0; i < PING_WINDOW_SIZE; i++)
        PingWindow[i] = 0.0;
    PingWindowIdx = 0;
    PingWindowCount = 0;
}

simulated function Ping()
{
    Pong();
}

simulated function Pong()
{
    local float RawPing;

    bPingReceived = true;
    RawPing = Level.TimeSeconds - PingSendTime;

    // Cap at max ping (configurable via MutUTComp.MaxPing, default 0.150)
    if(RawPing > MaxPing)
        RawPing = MaxPing;

    // No separate spike rejection: the median of 5 already ignores one or two
    // outliers, and replacing high samples with the median kept a real rise in
    // ping (say 30ms -> 90ms) out of the window for good.

    // Write into circular buffer
    PingWindow[PingWindowIdx] = RawPing;
    PingWindowIdx = (PingWindowIdx + 1) % PING_WINDOW_SIZE;
    if(PingWindowCount < PING_WINDOW_SIZE)
        PingWindowCount++;

    numPings++;

    // Use median for stability — converges in ~2.5s (5 samples x 0.5s)
    PredictedPing = GetMedianPing();
    default.PredictedPing = PredictedPing;
}

simulated function float GetMedianPing()
{
    return Median5(PingWindow[0], PingWindow[1], PingWindow[2], PingWindow[3], PingWindow[4], PingWindowCount);
}

// Sort-free median of the first Count (up to 5) values using pairwise comparisons
simulated function float Median5(float A, float B, float C, float D, float E, int Count)
{
    local float Tmp;

    if(Count <= 0)
        return 0.0;
    if(Count == 1)
        return A;
    if(Count == 2)
        return (A + B) * 0.5;

    if(Count == 3)
    {
        // Median of 3: sort and return middle
        if(A > B) { Tmp = A; A = B; B = Tmp; }
        if(B > C) { Tmp = B; B = C; C = Tmp; }
        if(A > B) { Tmp = A; A = B; B = Tmp; }
        return B;
    }

    if(Count == 4)
    {
        // Median of 4: average of 2nd and 3rd
        if(A > B) { Tmp = A; A = B; B = Tmp; }
        if(C > D) { Tmp = C; C = D; D = Tmp; }
        if(A > C) { Tmp = A; A = C; C = Tmp; }
        if(B > D) { Tmp = B; B = D; D = Tmp; }
        if(B > C) { Tmp = B; B = C; C = Tmp; }
        return (B + C) * 0.5;
    }

    // Median of 5
    // Sorting network for 5 elements — find the 3rd smallest
    if(A > B) { Tmp = A; A = B; B = Tmp; }
    if(C > D) { Tmp = C; C = D; D = Tmp; }
    if(A > C) { Tmp = A; A = C; C = Tmp; Tmp = B; B = D; D = Tmp; }
    // Now A <= C, A is smallest of {A,B,C,D}. E is unsorted.
    if(B > E) { Tmp = B; B = E; E = Tmp; }
    if(B > C) { Tmp = B; B = C; C = Tmp; }
    if(D > E) { Tmp = D; D = E; E = Tmp; }
    if(C > D) { Tmp = C; C = D; D = Tmp; }
    return C;
}

// Client: answer the server's ping straight away.
simulated function ClientSrvPing(byte Seq)
{
    ServerSrvPong(Seq);
}

// Server: one round trip measured.
function ServerSrvPong(byte Seq)
{
    if(!bSrvPingOut || Seq != SrvPingSeq)
        return;   // an old or duplicate answer
    bSrvPingOut = false;
    SrvRTTWindow[SrvRTTIdx] = Level.TimeSeconds - SrvPingSentTime;
    SrvRTTIdx = (SrvRTTIdx + 1) % PING_WINDOW_SIZE;
    if(SrvRTTCount < PING_WINDOW_SIZE)
        SrvRTTCount++;
    ServerRTT = Median5(SrvRTTWindow[0], SrvRTTWindow[1], SrvRTTWindow[2], SrvRTTWindow[3], SrvRTTWindow[4], SrvRTTCount);
}

simulated function Tick(float deltatime)
{
    super.Tick(deltatime);
    if(Level.NetMode != NM_Client)
    {
        // Server: ping the owning client twice a second (a lost one is resent).
        if(Level.NetMode != NM_Standalone && PlayerController(Owner) != None
            && ((!bSrvPingOut && Level.TimeSeconds > SrvPingSentTime + SRV_PING_PERIOD)
                || (bSrvPingOut && Level.TimeSeconds > SrvPingSentTime + SRV_PING_TIMEOUT)))
        {
            SrvPingSeq++;
            SrvPingSentTime = Level.TimeSeconds;
            bSrvPingOut = true;
            ClientSrvPing(SrvPingSeq);
        }
        return;
    }
    if(bPingReceived && Level.TimeSeconds > PingSendTime + PingTweenTime)
    {
        PingSendTime = Level.TimeSeconds;
        bPingReceived = false;
        Ping();
    }
}

defaultproperties
{
     bPingReceived=True
     NetUpdateFrequency=200.000000
     NetPriority=5.000000
     PingTweenTime=0.5
     MaxPing=0.150
}
