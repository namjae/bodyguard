defmodule BodyguardTest do
  alias BodyguardTest.{Context, User, Resource}

  use ExUnit.Case, async: true
  doctest Bodyguard

  defmodule User do
    defstruct [auth_result: :ok, auth_scope: :new_scope]
  end

  defmodule Resource do
    defstruct []
  end

  defmodule Context do
    defmodule Policy do
      def guard(%User{auth_result: result}, _action, _params), do: result

      def scope(%User{auth_scope: nil}, Resource, scope, _params), do: scope
      def scope(%User{auth_scope: scope}, Resource, _scope, _params), do: scope
    end

    defmodule OtherPolicy do
      def guard(_user, _action, _params), do: {:error, :other_result}

      def scope(_user, Resource, _scope, _params), do: :other_scope
    end
  end

  defmodule ResourceController do
    def action(conn, _params) do
      with :ok <- Bodyguard.guard(conn, Context, :access) do
        conn
      end
    end

    def action!(conn, _params) do
      Bodyguard.guard!(conn, Context, :access)
      conn
    end
  end

  defmodule FallbackController do
    def call(_conn, {:error, _reason}), do: :fallback_result
  end

  test "basic authorization" do
    results = [
      {:ok, true},
      {{:error, :unauthorized}, false},
      {{:error, :not_found}, false}
    ]

    for {result, boolean} <- results do
      # Standard auth
      assert Bodyguard.guard(%User{auth_result: result}, Context, :access) == result

      # Boolean auth
      assert Bodyguard.can?(%User{auth_result: result}, Context, :access) == boolean

      # Error auth
      if boolean do
        assert Bodyguard.guard!(%User{auth_result: result}, Context, :access) == :ok
      else
        assert_raise Bodyguard.NotAuthorizedError, fn ->
          Bodyguard.guard!(%User{auth_result: result}, Context, :access)
        end
      end
    end
  end

  test "overriding the default policy" do
    assert Bodyguard.guard(%User{}, Context, :access, policy: Context.OtherPolicy) == {:error, :other_result}
    assert Bodyguard.scope(%User{}, Context, Resource, policy: Context.OtherPolicy) == :other_scope
  end

  test "overriding the error defaults" do
    exception = assert_raise Bodyguard.NotAuthorizedError, fn ->
      Bodyguard.guard!(%User{auth_result: {:error, :foo}}, Context, :access, error_message: "whoops", error_status: 404)
    end

    assert exception.message == "whoops"
    assert exception.status == 404
  end

  test "basic scope limiting" do
    assert Bodyguard.scope(%User{auth_scope: nil}, Context, Resource) == Resource

    # Test type resolution
    assert Bodyguard.scope(%User{auth_scope: :limited}, Context, Resource) == :limited
    assert Bodyguard.scope(%User{auth_scope: :limited}, Context, %Resource{}) == :limited
    assert Bodyguard.scope(%User{auth_scope: :limited}, Context, [%Resource{}]) == :limited
    # TODO: Check Ecto.Query
    assert_raise ArgumentError, fn ->
      Bodyguard.scope(%User{auth_scope: :limited}, Context, %{}) # Can't determine type of %{}
    end

  end

  test "current user using a function" do
    defmodule TestLoader do
      def current_resource(_actor), do: %User{auth_result: {:error, :custom_user}}
    end

    # Set config
    Application.put_env(:bodyguard, :resolve_user, {TestLoader, :current_resource})

    # Use custom loader
    assert Bodyguard.resolve_user(:actor) == %User{auth_result: {:error, :custom_user}}
    assert Bodyguard.guard(:actor, Context, :access) == {:error, :custom_user}

    # Reset config
    Application.delete_env(:bodyguard, :resolve_user)
  end

  test "setting default options via a plug" do
    conn = Plug.Test.conn(:get, "/")

    # Set options
    plug_opts = Bodyguard.Plug.PutOptions.init(policy: Context.OtherPolicy)
    conn = Bodyguard.Plug.PutOptions.call(conn, plug_opts)

    # Use them in controller actions
    assert ResourceController.action(conn, %{}) == {:error, :other_result}
    assert_raise Bodyguard.NotAuthorizedError, fn ->
      ResourceController.action!(conn, %{})
    end
  end

  test "authorizing via a plug" do
    conn = Plug.Test.conn(:get, "/") |> Plug.Conn.assign(:current_user, %User{})
    
    # Success
    plug_opts = Bodyguard.Plug.Guard.init(context: Context, action: :access)
    assert %Plug.Conn{} = Bodyguard.Plug.Guard.call(conn, plug_opts)

    # Failure (raise)
    plug_opts = Bodyguard.Plug.Guard.init(context: Context, action: :access,
      policy: Context.OtherPolicy)
    assert_raise Bodyguard.NotAuthorizedError, fn ->
      Bodyguard.Plug.Guard.call(conn, plug_opts)
    end

    # Failure (fallback recovery)
    plug_opts = Bodyguard.Plug.Guard.init(context: Context, action: :access, 
      policy: Context.OtherPolicy, fallback: FallbackController)
    assert Bodyguard.Plug.Guard.call(conn, plug_opts) == :fallback_result
  end
end
