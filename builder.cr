require "ecr"

class HtmlFile
  def initialize(@js_content : String)
  end

  ECR.def_to_s "index.html.ecr"
end

system("tsc --lib \"es2015,dom\" client.ts")
js_content = File.read("./client.js")
resp_content = HtmlFile.new(js_content).to_s

File.write("./out.html", resp_content)
