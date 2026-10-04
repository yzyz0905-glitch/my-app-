/* global supabase */
(function () {
  "use strict";

  const config = window.PADLET_SUPABASE_CONFIG || {};
  const TABLES = Object.freeze({
    boards: "boards",
    sections: "sections",
    posts: "posts",
    postLikes: "post_likes",
    postComments: "post_comments",
    postModeration: "post_moderation",
    boardMembers: "board_members"
  });
  const RPCS = Object.freeze({
    createBoard: "create_board_with_owner",
    joinBoard: "join_board_as_student",
    joinBoardByLegacyId: "join_board_by_legacy_id",
    reorderBoardSections: "reorder_board_sections",
    reorderBoardWallPosts: "reorder_board_wall_posts"
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
    const currentUser = await getCurrentUser();

    const [boardResult, sectionsResult, postsResult, likesResult, commentsResult, moderationResult] = await Promise.all([
      supabaseClient.from(TABLES.boards).select("*").eq("id", boardId).maybeSingle(),
      supabaseClient.from(TABLES.sections).select("*").eq("board_id", boardId).order("sort_order").order("id"),
      supabaseClient.from(TABLES.posts).select("*").eq("board_id", boardId).order("created_at", { ascending: false }),
      supabaseClient.from(TABLES.postLikes).select("*").eq("board_id", boardId),
      supabaseClient.from(TABLES.postComments).select("*").eq("board_id", boardId).order("created_at"),
      supabaseClient.from(TABLES.postModeration)
        .select("post_id,is_hidden,hidden_by,hidden_at,updated_at,posts!inner(board_id)")
        .eq("posts.board_id", boardId)
    ]);

    for (const result of [boardResult, sectionsResult, postsResult, likesResult, commentsResult, moderationResult]) {
      if (result.error) throw result.error;
    }

    return {
      board: boardResult.data,
      currentUserId: currentUser?.id || null,
      sections: sectionsResult.data || [],
      posts: postsResult.data || [],
      likes: likesResult.data || [],
      comments: commentsResult.data || [],
      moderation: (moderationResult.data || []).map(({ posts, ...moderation }) => moderation)
    };
  }

  async function getBoardMembershipRole(boardId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const user = await getCurrentUser();
    if (!user) return null;
    const { data, error } = await supabaseClient
      .from(TABLES.boardMembers)
      .select("role")
      .eq("board_id", boardId)
      .eq("user_id", user.id)
      .maybeSingle();
    if (error) throw error;
    return data?.role || null;
  }

  async function fetchSections(boardId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return [];
    const { data, error } = await supabaseClient
      .from(TABLES.sections)
      .select("*")
      .eq("board_id", boardId)
      .order("sort_order")
      .order("id");
    if (error) throw error;
    return data || [];
  }

  async function reorderBoardSections(boardId, orderedSectionIds) {
    const supabaseClient = getClient();
    if (!supabaseClient) throw new Error("Supabase client is not configured.");
    const { error } = await supabaseClient.rpc(RPCS.reorderBoardSections, {
      target_board_id: boardId,
      ordered_section_ids: orderedSectionIds
    });
    if (error) throw error;
  }

  async function reorderBoardWallPosts(boardId, orderedPostIds) {
    const supabaseClient = getClient();
    if (!supabaseClient) throw new Error("Supabase client is not configured.");
    const { error } = await supabaseClient.rpc(RPCS.reorderBoardWallPosts, {
      target_board_id: boardId,
      ordered_post_ids: orderedPostIds
    });
    if (error) throw error;
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

  async function updatePostPosition(postId, boardId, canvasX, canvasY) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { data, error } = await supabaseClient
      .from(TABLES.posts)
      .update({ canvas_x: canvasX, canvas_y: canvasY })
      .eq("id", postId)
      .eq("board_id", boardId)
      .select("id,board_id,canvas_x,canvas_y")
      .single();
    if (error) throw error;
    return data;
  }

  async function updatePostDisplayOrder(postId, boardId, displayOrder) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { data, error } = await supabaseClient
      .from(TABLES.posts)
      .update({ display_order: displayOrder })
      .eq("id", postId)
      .eq("board_id", boardId)
      .select("id,board_id,display_order")
      .single();
    if (error) throw error;
    return data;
  }

  async function addPostLike(boardId, postId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const user = await getCurrentUser();
    if (!user) throw new Error("Supabase user session is required to like a post.");
    const { data, error } = await supabaseClient
      .from(TABLES.postLikes)
      .insert({ board_id: boardId, post_id: postId, user_id: user.id })
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  async function removePostLike(postId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const user = await getCurrentUser();
    if (!user) throw new Error("Supabase user session is required to unlike a post.");
    const { data, error } = await supabaseClient
      .from(TABLES.postLikes)
      .delete()
      .eq("post_id", postId)
      .eq("user_id", user.id)
      .select("*");
    if (error) throw error;
    return data?.[0] || null;
  }

  async function createComment({ boardId, postId, authorLabel, content }) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const user = await getCurrentUser();
    if (!user) throw new Error("Supabase user session is required to comment.");
    const { data, error } = await supabaseClient
      .from(TABLES.postComments)
      .insert({
        board_id: boardId,
        post_id: postId,
        author_user_id: user.id,
        author_label: authorLabel,
        content
      })
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  async function updateComment(commentId, content) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { data, error } = await supabaseClient
      .from(TABLES.postComments)
      .update({ content })
      .eq("id", commentId)
      .select("*")
      .single();
    if (error) throw error;
    return data;
  }

  async function deleteComment(commentId) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const { error } = await supabaseClient
      .from(TABLES.postComments)
      .delete()
      .eq("id", commentId);
    if (error) throw error;
    return true;
  }

  async function setPostVisibility(postId, isHidden) {
    const supabaseClient = getClient();
    if (!supabaseClient) return null;
    const user = await getCurrentUser();
    if (!user) throw new Error("Supabase user session is required to moderate a post.");
    const { data, error } = await supabaseClient
      .from(TABLES.postModeration)
      .upsert({
        post_id: postId,
        is_hidden: isHidden
      }, { onConflict: "post_id" })
      .select("*")
      .single();
    if (error) throw error;
    return data;
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

  function subscribeToBoardActivity(boardId, handlers = {}) {
    const supabaseClient = getClient();
    if (!supabaseClient || !boardId) return null;

    const channel = supabaseClient
      .channel(`padlet-board-activity-${boardId}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: TABLES.postLikes, filter: `board_id=eq.${boardId}` },
        payload => handlers.likes?.(payload)
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: TABLES.postComments, filter: `board_id=eq.${boardId}` },
        payload => handlers.comments?.(payload)
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: TABLES.postModeration },
        payload => handlers.moderation?.(payload)
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
    fetchSections,
    fetchPosts,
    createPost,
    updatePost,
    deletePost,
    updatePostPosition,
    updatePostDisplayOrder,
    reorderBoardSections,
    reorderBoardWallPosts,
    addPostLike,
    removePostLike,
    createComment,
    updateComment,
    deleteComment,
    setPostVisibility,
    getBoardMembershipRole,
    subscribeToPosts,
    subscribeToBoardActivity
  });
})();
