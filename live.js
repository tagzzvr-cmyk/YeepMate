(() => {
  const cfg = window.YEEPSHUB_SUPABASE;
  const supabaseLib = window.supabase;
  const home = document.getElementById('welcome');
  const main = document.getElementById('gameArea');
  const queueScreen = document.getElementById('liveQueueScreen');
  const queueText = document.getElementById('queueText');
  const queueSub = document.getElementById('queueSub');
  const liveBar = document.getElementById('liveMatchBar');
  const liveTitle = document.getElementById('liveTitle');
  const liveSub = document.getElementById('liveSub');
  const leaveBtn = document.getElementById('leaveLive');
  let client = null, playerId = null, playerName = null, matchId = null;
  let opponentId = null, color = null, channel = null, queueTimer = null, pollTimer = null, busy = false;

  function status(text, sub) {
    queueText.textContent = text;
    queueSub.textContent = sub || '';
  }
  function showQueue() {
    home.style.display = 'none'; main.style.display = 'none';
    queueScreen.style.display = 'block'; liveBar.style.display = 'none';
  }
  function showMatch() {
    queueScreen.style.display = 'none'; home.style.display = 'none';
    main.style.display = 'grid'; liveBar.style.display = 'flex';
    document.getElementById('botLevel').disabled = true;
  }
  function showHome() {
    clearInterval(queueTimer); clearInterval(pollTimer);
    queueTimer = pollTimer = null;
    if (channel) client.removeChannel(channel);
    channel = null; matchId = opponentId = color = null; busy = false; window.yeepMateLivePlayerColor = null;
    liveBar.style.display = 'none'; queueScreen.style.display = 'none';
    main.style.display = 'none'; home.style.display = 'block';
    document.getElementById('botLevel').disabled = false;
  }
  function rpc(name, args) { return client.rpc(name, args); }

  async function tryQueue() {
    if (busy || !playerId) return;
    busy = true;
    const { data, error } = await rpc('yeepmate_join_queue', {
      p_player_id: playerId, p_player_name: playerName
    });
    busy = false;
    if (error) { status('Could not join queue', error.message); return; }
    if (data && data.state === 'matched') {
      clearInterval(queueTimer); queueTimer = null;
      matchId = data.match_id; color = data.color;
      opponentId = data.opponent_id;
      liveTitle.textContent = 'LIVE MATCH · ' + data.opponent_name;
      liveSub.textContent = 'You are playing ' + color.toUpperCase() + ' · ' + playerName;
      window.yeepMateSetLivePlayer(color, playerId, data.white_player_id, data.black_player_id);
      showMatch();
      await attachMatch();
    } else {
      status('Waiting for an opponent…', 'You are in the live queue. Keep this page open.');
    }
  }
  async function attachMatch() {
    const { data, error } = await rpc('yeepmate_get_match', {
      p_match_id: matchId, p_player_id: playerId
    });
    if (error) { status('Could not load match', error.message); return; }
    applyMatch(data);
    channel = client.channel('yeepmate-match-' + matchId)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'yeepmate_matches',
        filter: 'id=eq.' + matchId
      }, payload => applyMatch(payload.new))
      .subscribe();
    pollTimer = setInterval(async () => {
      const result = await rpc('yeepmate_get_match', {p_match_id:matchId,p_player_id:playerId});
      if (!result.error && result.data) applyMatch(result.data);
    }, 2500);
  }
  function applyMatch(row) {
    if (!row || row.id !== matchId) return;
    if (row.status === 'abandoned') {
      liveSub.textContent = 'Your opponent left the match.';
      return;
    }
    if (Array.isArray(row.moves)) window.yeepMateApplyRemoteMoves(row.moves);
    const myTurn = row.turn_player_id === playerId;
    liveSub.textContent = row.status === 'active'
      ? (myTurn ? 'Your turn · ' : 'Opponent’s turn · ') + (color || '').toUpperCase()
      : 'Match finished · ' + row.status;
  }
  window.yeepMateOnLocalMove = async (fen, moves, turn, gameStatus) => {
    if (!matchId || busy) return;
    busy = true;
    const nextId = turn === 'w'
      ? window.yeepMateWhitePlayerId
      : window.yeepMateBlackPlayerId;
    const { error } = await rpc('yeepmate_submit_move', {
      p_match_id: matchId, p_player_id: playerId, p_fen: fen,
      p_moves: moves, p_next_player_id: nextId, p_status: gameStatus
    });
    busy = false;
    if (error) {
      liveSub.textContent = 'Move could not sync: ' + error.message;
      const result = await rpc('yeepmate_get_match', {p_match_id:matchId,p_player_id:playerId});
      if (!result.error && result.data) applyMatch(result.data);
    }
  };
  window.startYeepMateLive = async () => {
    if (!cfg || !cfg.url || !cfg.anonKey || !supabaseLib) {
      alert('Supabase setup is missing. Check supabase-config.js and refresh.');
      return;
    }
    if (!client) client = supabaseLib.createClient(cfg.url, cfg.anonKey);
    playerId = localStorage.getItem('yeepmate_player_id');
    if (!playerId) {
      playerId = crypto.randomUUID();
      localStorage.setItem('yeepmate_player_id', playerId);
    }
    if (!playerName) playerName = 'Guest-' + playerId.slice(0,4).toUpperCase();
    status('Joining live queue…', 'Looking for another YeepMate player.');
    showQueue();
    await tryQueue();
    if (!matchId) queueTimer = setInterval(tryQueue, 2500);
  };
  document.getElementById('cancelQueue').addEventListener('click', async () => {
    if (client && playerId) await rpc('yeepmate_leave_queue', {p_player_id:playerId});
    showHome();
  });
  leaveBtn.addEventListener('click', async () => {
    if (client && playerId) await rpc('yeepmate_leave_queue', {p_player_id:playerId});
    showHome();
  });
})();