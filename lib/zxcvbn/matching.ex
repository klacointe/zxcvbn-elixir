defmodule ZXCVBN.Matching do
  @moduledoc """
  Matching module
  """
  import ZXCVBN.AdjacencyGraphs, only: [adjacency_graph: 0]
  import ZXCVBN.FrequencyLists, only: [frequency_lists: 0]

  alias ZXCVBN.Scoring

  @frequency_lists frequency_lists()
  @adjacency_graphs adjacency_graph()

  def build_ranked_dict(ordered_list) do
    ordered_list
    |> Enum.with_index(1)
    |> Enum.into(%{})
  end

  def add_frequency_lists(ranked_dictionaries, frequency_lists \\ @frequency_lists) do
    Enum.reduce(frequency_lists, ranked_dictionaries, fn {name, lst}, ranked_dictionaries ->
      Map.put(ranked_dictionaries, name, build_ranked_dict(lst))
    end)
  end

  @l33t_table %{
    a: ["4", "@"],
    b: ["8"],
    c: ["(", "{", "[", "<"],
    e: ["3"],
    g: ["6", "9"],
    i: ["1", "!", "|"],
    l: ["1", "|", "7"],
    o: ["0"],
    s: ["$", "5"],
    t: ["+", "7"],
    x: ["%"],
    z: ["2"]
  }

  @regexen ~r'19\d\d|200\d|201\d'
  @date_max_year 2_050
  @date_min_year 1_000
  @date_splits %{
    # for length-4 strings, eg 1191 or 9111, two ways to split:
    "4": [
      # 1 1 91 (2nd split starts at index 1, 3rd at index 2)
      [1, 2],
      # 91 1 1
      [2, 3]
    ],
    "5": [
      # 1 11 91
      [1, 3],
      # 11 1 91
      [2, 3]
    ],
    "6": [
      # 1 1 1991
      [1, 2],
      # 11 11 91
      [2, 4],
      # 1991 1 1
      [4, 5]
    ],
    "7": [
      # 1 11 1991
      [1, 3],
      # 11 1 1991
      [2, 3],
      # 1991 1 11
      [4, 5],
      # 1991 11 1
      [4, 6]
    ],
    "8": [
      # 11 11 1991
      [2, 4],
      # 1991 11 11
      [4, 6]
    ]
  }

  @matcher_types [
    :dictionary,
    :reverse_dictionary,
    :l33t,
    :spatial,
    # :repeat,
    # :sequence,
    # :regex,
    # :date
  ]

  @doc """
  omnimatch -- perform all matches
  """
  def omnimatch(password, ranked_dictionaries) do
    @matcher_types
    |> Enum.reduce([], fn matcher_type, matches ->
      [apply(__MODULE__, :"#{matcher_type}_match", [password, ranked_dictionaries]) | matches]
    end)
    |> List.flatten()
    |> _sort()
  end

  # dictionary match (common passwords, english, last names, etc)
  @doc false
  def dictionary_match(password, ranked_dictionaries) do
    length = String.length(password)
    password_lower = String.downcase(password)

    for {dictionary_name, ranked_dict} <- ranked_dictionaries,
        i <- 0..(length - 1),
        j <- i..(length - 1) do
      ranked_dict_values = Map.keys(ranked_dict)
      if (word = String.slice(password_lower, i, j + 1 - i)) in ranked_dict_values do
        token = String.slice(password_lower, i, j + 1 - i)
        rank = ranked_dict[word]

        %{
          pattern: :dictionary,
          i: i,
          j: j,
          token: token,
          matched_word: word,
          rank: rank,
          dictionary_name: dictionary_name,
          reversed: false,
          l33t: false
        }
      end
    end
    |> Enum.reject(&is_nil/1)
    |> _sort()
  end

  @doc false
  def reverse_dictionary_match(password, ranked_dictionaries) do
    length = String.length(password)

    password
    |> String.reverse()
    |> dictionary_match(ranked_dictionaries)
    |> Enum.map(fn %{token: token} = match ->
      match
      |> Map.put(:token, String.reverse(token))
      |> Map.put(:reversed, true)
      |> Map.put(:i, length - 1 - match[:j])
      |> Map.put(:j, length - 1 - match[:i])
    end)
    |> _sort()
  end

  @doc false
  def l33t_match(password, ranked_dictionaries, l33t_table \\ @l33t_table) do
    for sub <- enumerate_l33t_subs(relevant_l33t_subtable(password, l33t_table)) do
      subbed_password = translate(password, sub)

      for match <- dictionary_match(subbed_password, ranked_dictionaries) do
        token = String.slice(password, match[:i], match[:j] + 1 - match[:i])
        # only return the matches that contain an actual substitution
        if String.downcase(token) !== Map.get(match, :matched_word) do
          # subset of mappings in sub that are in use for this match
          token_graphemes = String.graphemes(token)

          match_sub =
            for {subbed_chr, chr} <- sub, subbed_chr in token_graphemes do
              {subbed_chr, chr}
            end

          sub_display =
            Enum.map_join(match_sub, ", ", fn {k, v} ->
              "#{k} -> #{v}"
            end)

          match
          |> Map.put(:l33t, true)
          |> Map.put(:token, token)
          |> Map.put(:sub, match_sub)
          |> Map.put(:sub_display, sub_display)
        end
      end
    end
    |> Enum.reject(fn
      nil ->
        true

      %{token: token} ->
        String.length(token) <= 1

      _ ->
        false
    end)
    |> _sort()
  end

  defp relevant_l33t_subtable(password, table) do
    password_chars = String.graphemes(password)

    for {letter, subs} <- table do
      relevant_subs =
        Enum.filter(subs, fn sub ->
          sub in password_chars
        end)

      case relevant_subs do
        [_ | _] ->
          {letter, relevant_subs}

        _ ->
          nil
      end
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp enumerate_l33t_subs(table) do
    keys = Map.keys(table)

    l33t_helper(table, keys, [%{}])
    # subs = l33t_helper(table, keys, [%{}])

    # for sub <- subs, {l33t_chr, chr} <- sub, into: [] do
    #   {l33t_chr, chr}
    # end
  end

  defp translate(string, chr_map) do
    for char <- String.graphemes(string) do
      if chr = Map.get(chr_map, char, false) do
        chr
      else
        char
      end
    end
    |> Enum.join("")
  end

  defp l33t_helper(table, [first_key | rest_keys], subs) do
    next_subs =
      for l33t_chr <- Map.get(table, first_key), sub <- subs do
        dup_l33t_index =
          Enum.reduce(0..(map_size(sub) - 1), -1, fn i, dup_l33t_index ->
            if get_in(sub, [i, 0]) === l33t_chr do
              i
            else
              dup_l33t_index
            end
          end)

        if dup_l33t_index === -1 do
          [Map.put(sub, l33t_chr, first_key)]
          # "#{sub}#{l33t_chr}#{first_key}" |> String.graphemes()
        else
          sub_alternative =
            sub
            |> Map.drop([dup_l33t_index])
            |> Map.put(l33t_chr, first_key)
            # "#{sub}#{l33t_chr}#{first_key}" |> String.graphemes() |> Kernel.--([dup_l33t_index])

          [sub, sub_alternative]
        end
      end
      |> List.flatten()

    subs = dedup(next_subs)
    l33t_helper(table, rest_keys, subs)
  end

  defp l33t_helper(_table, _keys, subs) do
    subs
  end

  def dedup(subs) do
    {deduped, _} =
      Enum.reduce(subs, {[], []}, fn sub, {deduped, members} ->
        assoc =
          sub
          |> Enum.into(%{}, fn {v, k} -> {k, v} end)
          |> Enum.sort()

        label =
          Enum.map_join(assoc, "-", fn {k, v} ->
            "#{k},#{v}"
          end)

        if label in members do
          {deduped, members}
        else
          {[sub | deduped], [label | members]}
        end
      end)

    deduped
  end

  @greedy ~r'(.+)\1+'
  @lazy ~r'(.+?)\1+'
  @lazy_anchored ~r'^(.+?)\1+$'
  # repeats (aaa, abcabcabc) and sequences (abcdef)
  @doc false
  def repeat_match(password, ranked_dictionaries) do
    length = String.length(password)

    Enum.reduce_while(0..length, [], fn i, matches ->
      {_, part} = String.split_at(password, i)
      greedy_match = Regex.run(@greedy, part)
      lazy_match = Regex.run(@lazy, part)

      case greedy_match do
        [greedy_first, _] ->
          greedy_len = String.length(greedy_first)
          [lazy_first, _] = lazy_match
          lazy_len = String.length(lazy_first)

          {{i, j}, token, base_token} =
            if greedy_len > lazy_len do
              # greedy beats lazy for 'aabaab'
              #   greedy: [aabaab, aab]
              #   lazy:   [aa,     a]
              {
                @greedy |> Regex.run(part, return: :index) |> hd(),
                greedy_first,
                # greedy's repeated string might itself be repeated, eg.
                # aabaab in aabaabaabaab.
                # run an anchored lazy match on greedy's repeated string
                # to find the shortest repeated string
                Regex.run(@lazy_anchored, greedy_first) |> List.last()
              }
            else
              {
                @lazy |> Regex.run(part, return: :index) |> hd(),
                lazy_first,
                List.last(lazy_match)
              }
            end

          # recursively match and score the base string
          base_analysis =
            Scoring.most_guessable_match_sequence(
              base_token,
              omnimatch(password, ranked_dictionaries)
            )

          match = %{
            pattern: :repeat,
            i: i,
            j: j,
            token: token,
            base_token: base_token,
            base_guesses: Map.get(base_analysis, :base_guesses),
            base_matches: Map.get(base_analysis, :base_matches),
            repeat_count: String.length(token) / String.length(base_token)
          }

          {:cont, match}

        _ ->
          {:halt, matches}
      end
    end)
  end

  # TODO: finish impl
  @doc false
  def spatial_match(password, graphs \\ @adjacency_graphs, _ranked_dictionaries) do
    for {graph_name, graph} <- graphs do
      spatial_match_helper(password, graph, graph_name)
    end
    |> _sort()
  end

  @shifted_rx ~r'[~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:"ZXCVBNM<>?]'

  def spatial_match_helper(password, graph, graph_name) do
    length = String.length(password)

    password
    |> do_spatial_match(graph, graph_name, 0, length, [])
    |> List.flatten()
  end

  defp do_spatial_match(password, graph, graph_name, i, length, matches) when i < (length - 1) do
    j = i + 1

    shifted_count =
      if graph_name in ~w(qwerty dvorak) and
           Regex.match?(@shifted_rx, String.at(password, i)) do
        # initial character is shifted
        1
      else
        0
      end

    {matches, i} = spatial_loop(password, i, j, graph, graph_name, shifted_count, matches)
    do_spatial_match(password, graph, graph_name, i, length, matches)
  end
  defp do_spatial_match(_, _, _, _, _, matches), do: matches

  defp spatial_loop(password, i, j, graph, graph_name, shifted_count, matches, turns \\ 0, last_direction \\ nil) do
    prev_char = String.at(password, j - 1)
    found = false
    cur_direction = -1

    adjacents =
      graph
      |> is_map()
      |> if do
        Map.get(graph, prev_char, [])
      else
        []
      end
    length = String.length(password)

    # consider growing pattern by one character if j hasn't gone
    # over the edge.
    {_cur_direction, found, last_direction, turns, shifted_count} =
      if j < length do
        cur_char = String.at(password, j)
        Enum.reduce_while(
          adjacents,
          {cur_direction, found, last_direction, turns, shifted_count},
          fn adj, {cur_direction, found, last_direction, turns, shifted_count} ->
            cur_direction = cur_direction + 1
            if is_binary(adj) and cur_char in String.graphemes(adj) do
              found = true
              found_direction = cur_direction
              cur_char_index = adj |> :binary.match(cur_char) |> elem(0)
              # index 1 in the adjacency means the key is shifted,
              # 0 means unshifted: A vs a, % vs 5, etc.
              # for example, 'q' is adjacent to the entry '2@'.
              # @ is shifted w/ index 1, 2 is unshifted.
              shifted_count = if cur_char_index === 1, do: shifted_count + 1, else: shifted_count

              {turns, last_direction} =
                if last_direction === found_direction do
                  {turns, last_direction}
                else
                  # adding a turn is correct even in the initial case when last_direction is null:
                  # every spatial pattern starts with a turn.
                  {turns + 1, found_direction}
                end

              {:halt, {cur_direction, found, last_direction, turns, shifted_count}}
            else
              {:cont, {cur_direction, found, last_direction, turns, shifted_count}}
            end
          end
        )
      else
        {cur_direction, found, last_direction, turns, shifted_count}
      end

    if found do
      # if the current pattern continued, extend j and try to grow again
      spatial_loop(password, i, j + 1, graph, graph_name, shifted_count, matches, turns, last_direction)
    else
      # don't consider length 1 or 2 chains.
      if j - i > 2 do
        # ...and then start a new search for the rest of the password.
        {
          [
            %{
              pattern: :spatial,
              i: i,
              j: j - 1,
              token: String.slice(password, i, j),
              graph: graph_name,
              turns: turns,
              shifted_count: shifted_count
            }
            | matches
          ],
          j
        }
      else
        {matches, j}
      end
    end
  end

  # TODO: finish impl
  def sequence_match("", _ranked_dictionaries), do: []

  def sequence_match(password, ranked_dictionaries) do
    # Identifies sequences by looking for repeated differences in unicode codepoint.
    # this allows skipping, such as 9753, and also matches some extended unicode sequences
    # such as Greek and Cyrillic alphabets.
    #
    # for example, consider the input 'abcdb975zy'
    #
    # password: a   b   c   d   b    9   7   5   z   y
    # index:    0   1   2   3   4    5   6   7   8   9
    # delta:      1   1   1  -2  -41  -2  -2  69   1
    #
    # expected result:
    # [(i, j, delta), ...] = [(0, 3, 1), (5, 7, -2), (8, 9, 1)]
    []
  end

  # TODO: finish impl
  def regex_match(password, regexen \\ @regexen, ranked_dictionaries) do
    []
  end

  # TODO: finish impl
  def date_match(password, ranked_dictionaries) do
    # a "date" is recognized as:
    #   any 3-tuple that starts or ends with a 2- or 4-digit year,
    #   with 2 or 0 separator chars (1.1.91 or 1191),
    #   maybe zero-padded (01-01-91 vs 1-1-91),
    #   a month between 1 and 12,
    #   a day between 1 and 31.
    #
    # note: this isn't true date parsing in that "feb 31st" is allowed,
    # this doesn't check for leap years, etc.
    #
    # recipe:
    # start with regex to find maybe-dates, then attempt to map the integers
    # onto month-day-year to filter the maybe-dates into dates.
    # finally, remove matches that are substrings of other matches to reduce noise.
    #
    # note: instead of using a lazy or greedy regex to find many dates over the full string,
    # this uses a ^...$ regex against every substring of the password -- less performant but leads
    # to every possible date match.
    []
  end

  # internal sorting
  defp _sort(list) do
    list
    |> Enum.sort(fn x1, x2 ->
      {x1[:i], x2[:j]} >= {x2[:i], x2[:j]}
    end)
  end
end
