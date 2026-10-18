# Repro for docs/m2-notes.md. After a garbage collection, a class-variable array (@@cases) and the
# real Cybertrain::Router's @routes end up as the same array: this prints "5 cases" and four
# NoMethodError lines instead of "1 cases". Swap @@cases for a plain constant-held object (or a
# module-level @cases) and it prints "1 cases". Build it with `spin test test/<copy>.rb` from this
# repo (it needs the cybertrain path dependency); copy it under test/ first.
# Stand-alone: no cybertrain. Two unrelated empty-array ivars/cvars.
class Case
  attr_reader :name, :block
  def initialize(name, block)
    @name = name
    @block = block
  end
end

module Suite
  @@cases = []

  def self.register(name, block)
    @@cases << Case.new(name, block)
  end

  def self.run!
    @@cases.each do |c|
      begin
        c.block.call
        puts "ok   #{c.name}"
      rescue StandardError => e
        puts "ERR  #{c.name}: #{e.class.name}"
      end
    end
    puts "#{@@cases.size} cases"
  end
end

def test(name, &block)
  Suite.register(name, block)
end

require "cybertrain/router"

i = 0
s = ""
while i < 300000
  s = "x" + i.to_s
  i += 1
end

router = Cybertrain::Router.new
router.get("/a") { |ctx| ctx.response.body = "a" }
router.get("/b") { |ctx| ctx.response.body = "b" }
router.get("/c") { |ctx| ctx.response.body = "c" }
router.get("/d") { |ctx| ctx.response.body = "d" }

test "works" do
  puts "routes: #{router.routes.size}"
end

Suite.run!
