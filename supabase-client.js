/* global supabase */
(function () {
  "use strict";

  const config = window.PADLET_SUPABASE_CONFIG || {};
  const TABLES = Object.freeze({
    boards: "boards",
    sections: "sections",
    posts: "posts",
    postModeration: "post_moderation",
    boardMembers: "board_members"
  });
  const RPCS = Object.freeze({
    createBoard: "create_board_with_owner",
    joinBoard: "join_board_as_student",
    joinBoardByLegacyId: "join_board_by_legacy_id"
  });

  let client = null;
  let initializationPromise = null;

  function isConfigured() {
    return Boolean(config.url && config.anonKey && window.supabase?.createClient);
  }

  function getClient() {
    if (!isConfigured()) return null;
    if (!client) {
      client = window.supabase.createClient(config.url, config.anonKey, {
        auth: {
          persistSession: true,
          autoRefreshToken: true,
          detectSessionInUrl: true
        }
      });
    }
    return client;
  }

  async function ensureAnonymousSession() {
    const supabaseClient = getClient();
    if (!supabaseClient) return { enabled: false, user: null };

    const { data: sessionData, error: sessionError } = await supabaseClient.auth.getSession();
    if (sessionError) throw sessionError;
    if (sessionData.session?.user) {
      return { enabled: true, user: sessionData.session.user };
    }

    const { data, error } = await supabaseClient.auth.signInAnonymously();
    if (error) throw error;
    return { enabled: true, user: data.user || data.session?.user || null };
  }

  async function getCurrentUser() {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { data, error } = await supabaseClient.auth.getUser();
    if (error) throw error;
    return data.user || null;
  }

  async function createBoard({ name, description = "", theme = "theme-pastel", currentView = "wall" }) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { data, error } = await supabaseClient.rpc(RPCS.createBoard, {
      board_name: name,
      board_description: description,
      board_theme: theme,
      board_view: currentView
    });
    if (error) throw error;
    return data;
  }

  async function joinBoard(boardId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { data, error } = await supabaseClient.rpc(RPCS.joinBoard, {
      target_board_id: boardId
    });
    if (error) throw error;
    return data;
  }

  async function joinBoardByLegacyId(legacyId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { data, error } = await supabaseClient.rpc(RPCS.joinBoardByLegacyId, {
      target_legacy_id: legacyId
    });
    if (error) throw error;
    return data;
  }

  async function listJoinedBoards() {
    const supabaseClient = getClient();
    if (!supabaseClient) return [];
    const { data, error } = await supabaseClient
      .from(TABLES.boardMembers)
      .select("role, boards(*)")
      .order("created_at", { ascending: false });
    if (error) throw error;
    return (data || []).map(entry => ({ ...entry.boards, membershipRole: entry.role }));
  }

  async function fetchBoardData(boardId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;

    const [boardResult, sectionsResult, postsResult] = await Promise.all([
      supabaseClient.from(TABLES.boards).select("*").eq("id", boardId).maybeSingle(),
      supabaseClient.from(TABLES.sections).select("*").eq("board_id", boardId).order("sort_order"),
      supabaseClient.from(TABLES.posts).select("*").eq("board_id", boardId).order("created_at", { ascending: false })
    ]);

    for (const result of [boardResult, sectionsResult, postsResult]) {
      if (result.error) throw result.error;
    }

    const postIds = (postsResult.data || []).map(post => post.id);
    let moderationResult = { data: [], error: null };
    if (postIds.length > 0) {
      moderationResult = await supabaseClient
        .from(TABLES.postModeration)
        .select("*")
        .in("post_id", postIds);
      if (moderationResult.error) throw moderationResult.error;
    }

    return {
      board: boardResult.data,
      sections: sectionsResult.data || [],
      posts: postsResult.data || [],
      moderation: moderationResult.data || []
    };
  }

  async function fetchPosts(boardId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return [];
    const { data, error } = await supabaseClient
      .from(TABLES.posts)
      .select("*")
      .eq("board_id", boardId)
      .order("created_at", { ascending: false });
    if (error) throw error;
    return data || [];
  }

  async function createPost(post) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const user = await getCurrentUser();
    if (!user) throw new Error("Supabase user session is required to create a post.");
    const { data, error } = await supabaseClient
      .from(TABLES.posts)
      .insert({
        board_id: post.boardId,
        section_id: post.sectionId || null,
        author_user_id: user.id,
        student_number: post.studentNumber,
        title: post.title,
        content: post.content || "",
        color: post.color || "yellow",
        image_url: post.imageUrl || "",
        link_url: post.linkUrl || "",
        pinned: Boolean(post.pinned),
        canvas_x: post.canvasX ?? 100,
        canvas_y: post.canvasY ?? 100,
        last_edited_by: user.id
      })
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  async function updatePost(postId, post) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const user = await getCurrentUser();
    if (!user) throw new Error("Supabase user session is required to update a post.");
    const { data, error } = await supabaseClient
      .from(TABLES.posts)
      .update({
        section_id: post.sectionId || null,
        student_number: post.studentNumber,
        title: post.title,
        content: post.content || "",
        color: post.color || "yellow",
        image_url: post.imageUrl || "",
        link_url: post.linkUrl || "",
        pinned: Boolean(post.pinned),
        canvas_x: post.canvasX ?? 100,
        canvas_y: post.canvasY ?? 100,
        last_edited_by: user.id
      })
      .eq("id", postId)
      .eq("board_id", post.boardId)
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  async function deletePost(postId, boardId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { error } = await supabaseClient
      .from(TABLES.posts)
      .delete()
      .eq("id", postId)
      .eq("board_id", boardId);
    if (error) throw error;
    return true;
  }

  function subscribeToPosts(boardId, handlers = {}) {
    const supabaseClient = getClient();
    if (!supabaseClient || !boardId) return null;

    const channel = supabaseClient
      .channel(`padlet-board-${boardId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: TABLES.posts, filter: `board_id=eq.${boardId}` },
        payload => handlers.posts?.(payload)
      )
      .subscribe();

    return {
      channel,
      unsubscribe: () => supabaseClient.removeChannel(channel)
    };
  }

  async function initialize() {
    if (initializationPromise) return initializationPromise;
    initializationPromise = (async () => {
      if (!isConfigured()) {
        return { enabled: false, user: null };
      }
      return ensureAnonymousSession();
    })();
    return initializationPromise;
  }

  window.PadletSupabase = Object.freeze({
    TABLES,
    RPCS,
    isConfigured,
    getClient,
    initialize,
    ensureAnonymousSession,
    getCurrentUser,
    createBoard,
    joinBoard,
    joinBoardByLegacyId,
    listJoinedBoards,
    fetchBoardData,
    fetchPosts,
    createPost,
    updatePost,
    deletePost,
    subscribeToPosts
  });
})();
