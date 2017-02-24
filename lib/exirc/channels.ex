defmodule ExIrc.Channels do
  @moduledoc """
  Responsible for managing channel state
  """
  use Irc.Commands

  import String, only: [downcase: 1]

  defmodule User do
    defstruct nick: '',
              user: '',
              host: '',
              mode: ''
  end

  defmodule Channel do
    defstruct name:  '',
              topic: '',
              users: [],
              modes: '',
              type:  ''
  end

  @doc """
  Initialize a new Channels data store
  """
  def init() do
    :gb_trees.empty()
  end

  ##################
  # Self JOIN/PART
  ##################

  @doc """
  Add a channel to the data store when joining a channel
  """
  def join(channel_tree, channel_name) do
    name = downcase(channel_name)
    case :gb_trees.lookup(name, channel_tree) do
      {:value, _} ->
        channel_tree
      :none ->
        :gb_trees.insert(name, %Channel{name: name}, channel_tree)
    end
  end

  @doc """
  Remove a channel from the data store when leaving a channel
  """
  def part(channel_tree, channel_name) do
    name = downcase(channel_name)
    case :gb_trees.lookup(name, channel_tree) do
      {:value, _} ->
        :gb_trees.delete(name, channel_tree)
      :none ->
        channel_tree
    end
  end

  ###########################
  # Channel Modes/Attributes
  ###########################

  @doc """
  Update the topic for a tracked channel when it changes
  """
  def set_topic(channel_tree, channel_name, topic) do
    name = downcase(channel_name)
    case :gb_trees.lookup(name, channel_tree) do
      {:value, channel} ->
        :gb_trees.enter(name, %{channel | topic: topic}, channel_tree)
      :none ->
        channel_tree
    end
  end

  @doc """
  Update the type of a tracked channel when it changes
  """
  def set_type(channel_tree, channel_name, channel_type) when is_binary(channel_type) do
    set_type(channel_tree, channel_name, String.to_char_list(channel_type))
  end
  def set_type(channel_tree, channel_name, channel_type) do
    name = downcase(channel_name)
    case :gb_trees.lookup(name, channel_tree) do
      {:value, channel} ->
        type = case channel_type do
             '@' -> :secret
             '*' -> :private
             '=' -> :public
        end
        :gb_trees.enter(name, %{channel | type: type}, channel_tree)
      :none ->
        channel_tree
    end
  end

  ####################################
  # Users JOIN/PART/AKAs(namechange)
  ####################################

  @doc """
  Add a user to a tracked channel when they join
  """
  def user_join(channel_tree, channel_name, nick) when not is_list(nick) do
    users_join(channel_tree, channel_name, [nick])
  end

  @doc """
  Add multiple users to a tracked channel (used primarily in conjunction with the NAMES command)
  """
  def users_join(channel_tree, channel_name, nicks) do
    pnicks = strip_rank(nicks)
    manipfn = fn(channel_nicks) -> :lists.usort(channel_nicks ++ pnicks) end
    users_manip(channel_tree, channel_name, manipfn)
  end

  def users_join(channel_tree, channel_name, nicks, user_prefixes) do
    pnicks = parse_users(nicks, user_prefixes)
    manipfn = fn(channel_nicks) -> :lists.usort(channel_nicks ++ pnicks) end
    users_manip(channel_tree, channel_name, manipfn)
  end

  @doc """
  Remove a user from a tracked channel when they leave
  """
  def user_part(channel_tree, channel_name, nick) do
    manipfn = fn(channel_nicks) -> Enum.filter(channel_nicks, fn(%{nick: cur_nick}) -> cur_nick !== nick end) end
    users_manip(channel_tree, channel_name, manipfn)
  end

  def user_quit(channel_tree, nick) do
    manipfn = fn(channel_nicks) -> Enum.filter(channel_nicks, fn(%{nick: cur_nick}) -> cur_nick !== nick end) end
    foldl = fn(channel_name, new_channel_tree) ->
      name = downcase(channel_name)
      users_manip(new_channel_tree, name, manipfn)
    end
    :lists.foldl(foldl, channel_tree, channels(channel_tree))
  end

  @doc """
  Update the nick of a user in a tracked channel when they change their nick
  """
  def user_rename(channel_tree, nick, new_nick) do
    manipfn = fn(channel_nicks) ->
      Enum.map(channel_nicks,
        fn(%{nick: cur_nick} = user) ->
          cond do
            cur_nick === nick -> %{user | nick: new_nick}
            true -> user
          end
        end
      )
      |> Enum.uniq
      |> Enum.sort
    end
    foldl = fn(channel_name, new_channel_tree) ->
      name = downcase(channel_name)
      users_manip(new_channel_tree, name, manipfn)
    end
    :lists.foldl(foldl, channel_tree, channels(channel_tree))
  end

  def mode_update(channel_tree, channel, %{type: "U", arg: upd_nick, mode: mode, add: add}) do
    mode_del_fn = fn(cur, new) ->
      Enum.filter(cur, fn(c) -> c !== new end)
    end
    mode_add_fn = fn(cur, new) ->
      cur <> new
    end

    users_manip(channel_tree, channel, fn(channel_nicks) ->
      Map.enum(channel_nicks, fn(user) ->
        case [user, add] do
          [%{nick: upd_nick, mode: cur_mode}, true] -> %{user | mode: mode_add_fn(mode_del_fn(cur_mode,mode),mode)}
          [%{nick: upd_nick, mode: cur_mode}, false] -> %{user | mode: mode_del_fn(cur_mode,mode)}
          _ -> user
        end
      end)
    end)
  end

  def mode_update(channel_tree, channel, mode) do
    channel_tree
  end

  ################
  # Introspection
  ################

  @doc """
  Get a list of all currently tracked channels
  """
  def channels(channel_tree) do
    (for {channel_name, _chan} <- :gb_trees.to_list(channel_tree), do: channel_name) |> Enum.reverse
  end

  @doc """
  Get a list of all users in a tracked channel
  """
  def channel_users(channel_tree, channel_name) do
    get_attr(channel_tree, channel_name, fn(%Channel{users: users}) -> Enum.map(users, fn(%{nick: nick}) -> nick end) end) |> Enum.reverse
  end

  @doc """
  Get a list of all users in a tracked channel
  """
  def channel_user_modes(channel_tree, channel_name) do
    get_attr(channel_tree, channel_name, fn(%Channel{users: users}) -> users end) |> Enum.reverse
  end

  @doc """
  Get the current topic for a tracked channel
  """
  def channel_topic(channel_tree, channel_name) do
    case get_attr(channel_tree, channel_name, fn(%Channel{topic: topic}) -> topic end) do
      []    -> "No topic"
      topic -> topic
    end
  end

  @doc """
  Get the type of a tracked channel
  """
  def channel_type(channel_tree, channel_name) do
    case get_attr(channel_tree, channel_name, fn(%Channel{type: type}) -> type end) do
      []   -> :unknown
      type -> type
    end
  end

  @doc """
  Determine if a user is present in a tracked channel
  """
  def channel_has_user?(channel_tree, channel_name, nick) do
    get_attr(channel_tree, channel_name, fn(%Channel{users: users}) ->
      Enum.any?(users, fn(%{nick: cur_nick}) -> cur_nick === nick end)
    end)
  end

  @doc """
  Get all channel data as a tuple of the channel name and a proplist of metadata.

  Example Result:

      [{"#testchannel", [users: ["userA", "userB"], topic: "Just a test channel.", type: :public] }]
  """
  def to_proplist(channel_tree) do
    for {channel_name, chan} <- :gb_trees.to_list(channel_tree) do
      {channel_name, [users: Enum.map(chan.users, fn(%{nick: nick}) -> nick end), topic: chan.topic, type: chan.type]}
    end |> Enum.reverse
  end

  ####################
  # Internal API
  ####################
  defp users_manip(channel_tree, channel_name, manipfn) do
    name = downcase(channel_name)
    case :gb_trees.lookup(name, channel_tree) do
      {:value, channel} ->
        channel_list = manipfn.(channel.users)
        :gb_trees.enter(channel_name, %{channel | users: channel_list}, channel_tree)
      :none ->
        channel_tree
    end
  end

  defp parse_users(nicks, user_prefixes) do
    nicks |> Enum.map(fn(<<p, nick::binary>> = n) ->
      case Enum.find(user_prefixes, nil, fn({_,prefix}) -> prefix === p end) do
        {mode, _} -> %User{nick: nick, mode: to_string([mode])}
        nil -> %User{nick: n}
      end
    end)
  end

  defp strip_rank(nicks) do
    nicks |> Enum.map(fn(n) -> %User{nick: case n do
        << "@", nick :: binary >> -> nick
        << "+", nick :: binary >> -> nick
        << "%", nick :: binary >> -> nick
        << "&", nick :: binary >> -> nick
        << "~", nick :: binary >> -> nick
        nick -> nick
      end}
    end)
  end

  defp get_attr(channel_tree, channel_name, getfn) do
    name = downcase(channel_name)
    case :gb_trees.lookup(name, channel_tree) do
      {:value, channel} -> getfn.(channel)
      :none -> {:error, :no_such_channel}
    end
  end

end
