# A minimal test harness, so the library does not depend on the framework
# just to run its tests. Same shape as cybertrain/test: register cases with
# `test "name" do ... end`, assert, end the file with KaisatsuTest.run!.
# Output is deterministic; `spin test` diffs it with test/<name>.rb.expected.
#
# The state lives in one object held by a constant, not in @@class variables:
# after a garbage collection a class-variable array can end up shared with
# another object (docs/m2-notes.md), which showed up as foreign cases in the run.
module KaisatsuTest
  class Failed < StandardError
  end

  class Registry
    def initialize
      @names = [""]
      @names.clear
      @blocks = [-> { nil }]
      @blocks.clear
      @failures = 0
      @assertions = 0
    end

    def add(name, block)
      @names << name
      @blocks << block
      nil
    end

    def count
      @assertions += 1
      nil
    end

    def run
      i = 0
      while i < @names.length
        name = @names[i]
        begin
          @blocks[i].call
          puts "ok   #{name}"
        rescue Failed => e
          @failures += 1
          puts "FAIL #{name}: #{e.message}"
        rescue StandardError => e
          @failures += 1
          puts "ERR  #{name}: #{e.class.name}"
        end
        i += 1
      end
      puts "#{@names.length} tests, #{@assertions} assertions, #{@failures} failures"
      exit(1) if @failures > 0
    end
  end

  REGISTRY = Registry.new

  def self.register(name, block)
    REGISTRY.add(name, block)
  end

  def self.count
    REGISTRY.count
  end

  def self.run!
    REGISTRY.run
  end
end

def test(name, &block)
  KaisatsuTest.register(name, block)
end

def assert(condition, message = "expected condition to be truthy")
  KaisatsuTest.count
  raise KaisatsuTest::Failed, message unless condition
end

def assert_equal(expected, actual)
  KaisatsuTest.count
  raise KaisatsuTest::Failed, "expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
end
