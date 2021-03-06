defmodule Absinthe.Middleware.DataloaderTest do
  use Absinthe.Case, async: true

  defmodule Schema do
    use Absinthe.Schema

    import Absinthe.Resolution.Helpers

    @organizations 1..3 |> Map.new(&{&1, %{
      id: &1,
      name: "Organization: ##{&1}"
    }})
    @users 1..3 |> Enum.map(&%{
      id: &1,
      name: "User: ##{&1}",
      organization_id: &1,
    })

    defp batch_load({:organization_id, %{pid: test_pid}}, sources) do
      send test_pid, :loading
      Map.new(sources, fn src ->
        {src, Map.fetch!(@organizations, src.organization_id)}
      end)
    end

    def context(ctx) do
      source = Dataloader.KV.new(&batch_load/2)
      loader = Dataloader.add_source(Dataloader.new, :test, source)

      Map.merge(ctx, %{
        loader: loader,
        test_pid: self()
      })
    end

    def plugins do
      [Absinthe.Middleware.Dataloader] ++ Absinthe.Plugin.defaults()
    end

    object :organization do
      field :id, :integer
      field :name, :string
    end

    object :user do
      field :name, :string
      field :foo_organization, :organization do
        resolve dataloader(:test, fn _, _, %{context: %{test_pid: pid}} ->
          {:organization_id, %{pid: pid}}
        end)
      end
      field :bar_organization, :organization do
        resolve dataloader(:test, :organization_id, args: %{pid: self()})
      end
    end

    query do
      field :users, list_of(:user) do
        resolve fn _, _, _ -> {:ok, @users} end
      end
      field :organization, :organization do
        arg :id, non_null(:integer)
        resolve fn _, %{id: id}, %{context: %{loader: loader, test_pid: test_pid}} ->
          loader
          |> Dataloader.load(:test, {:organization_id, %{pid: test_pid}}, %{organization_id: id})
          |> on_load(fn loader ->
            {:ok, Dataloader.get(loader, :test, {:organization_id, %{pid: test_pid}}, %{organization_id: id})}
          end)
        end
      end
    end

  end

  it "can resolve a field using the normal dataloader helper" do
    doc = """
    {
      users {
        organization: barOrganization {
          name
        }
      }
    }
    """
    expected_data = %{"users" => [%{"organization" => %{"name" => "Organization: #1"}}, %{"organization" => %{"name" => "Organization: #2"}}, %{"organization" => %{"name" => "Organization: #3"}}]}

    assert {:ok, %{data: data}} = Absinthe.run(doc, Schema)
    assert expected_data == data

    assert_receive(:loading)
    refute_receive(:loading)
  end

  it "can resolve batched fields cross-query that have different data requirements" do
    doc = """
    {
      users {
        organization: fooOrganization {
          name
        }
      }
      organization(id: 1) {
        id
      }
    }
    """
    expected_data = %{
      "users" => [
        %{"organization" => %{"name" => "Organization: #1"}},
        %{"organization" => %{"name" => "Organization: #2"}},
        %{"organization" => %{"name" => "Organization: #3"}},
      ],
      "organization" => %{"id" => 1},
    }

    assert {:ok, %{data: data}} = Absinthe.run(doc, Schema)
    assert expected_data == data
    assert_receive(:loading)
    refute_receive(:loading)
  end

end
