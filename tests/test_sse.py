from support import Package


def test_sse_parser_handles_every_byte_boundary_and_final_record():
    package = Package()
    try:
        value = package.lua(r'''
local sse=require('src.sse')
local parser=sse.new()
local source=": keepalive\r\nevent: token\r\ndata: first\r\ndata: 😀\r\n\r\ndata: [DONE]"
local records={}
for index=1,#source do
 local parsed=parser:push(source:sub(index,index))
 for _,record in ipairs(parsed)do records[#records+1]=record end
end
for _,record in ipairs(parser:finish())do records[#records+1]=record end
return records
''')
        assert value == [
            {"data": "first\n😀", "event": "token"},
            {"data": "[DONE]"},
        ]
    finally:
        package.close()


def test_sse_parser_handles_lf_cr_and_empty_data_lines():
    package = Package()
    try:
        value = package.lua(r'''
local parser=require('src.sse').new()
local records={}
for _,chunk in ipairs({"data: one\n\n", "data:\rdata: three\r\r"})do
 for _,record in ipairs(parser:push(chunk))do records[#records+1]=record end
end
for _,record in ipairs(parser:finish())do records[#records+1]=record end
return records
''')
        assert value == [{"data": "one"}, {"data": "\nthree"}]
    finally:
        package.close()


def test_sse_parser_enforces_lifecycle_without_a_size_limit():
    package = Package()
    try:
        value = package.lua(r'''
local sse=require('src.sse')
local parser=sse.new()
local first=pcall(parser.push,parser,string.rep("x",100000))
local other=sse.new()
other:finish()
local second=pcall(other.push,other,"x")
local third=pcall(other.finish,other)
return{first=first,second=second,third=third}
''')
        assert value == {"first": True, "second": False, "third": False}
    finally:
        package.close()
