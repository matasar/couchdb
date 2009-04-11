PS1 = 'js> '
PS2 = '..> '
_buffer = ''
_ = undefined

HttpResponse = function (data) {
  var header_index = data.search("\r\n")
  var body_index = data.search("\r\n\r\n")
  var status_line = data.slice(0, header_index)
  var header_lines = data.slice(header_index+2, body_index)
  var body = data.slice(body_index+4, data.length)
  this.status = parseInt(status_line.slice(8,12))
  this.headers = this.parseHeaders(header_lines)
  this.body = body
}

HttpResponse.prototype.parseHeaders = function (header_string) {
  var r = {}
  var header_lines = header_string.split("\r\n");
  for (i in header_lines) {
    var header = header_lines[i]
    var key_index = header.search(": ")
    var key = header.slice(0, key_index).toLowerCase()
    var body = header.slice(key_index + 2, header.length)
    if (r[key] == undefined) {
        r[key] = []
    } 
    r[key].push(body)
  }
  return r
}

HttpResponse.prototype.loadJson = function() {
  raw_data = this.body
  eval('this.__json_data='+raw_data)
  return this.__json_data
}

HttpClient = function(url) {
  this.url = url
}

HttpClient.prototype.head = function () {
    return new HttpResponse(headhttp(this.url));
}

HttpClient.prototype.get = function () {
    return new HttpResponse(gethttp(this.url));
}

HttpClient.prototype.put = function() {
    return new HttpResponse(puthttp(this.url));
}

HttpClient.prototype.post = function() {
    return new HttpResponse(posthttp(this.url));
}

HttpClient.prototype.delete = function() {
    return new HttpResponse(delhttp(this.url));
}

HttpClient.prototype.copy = function() {
    return new HttpResponse(copyhttp(this.url));
}

HttpClient.prototype.move = function() {
    return new HttpResponse(movehttp(this.url));
}

function _mainloop() {
  while(true) {
    if (_buffer.length == 0) {
      write(PS1)
    } else {
      write(PS2)
    }
    line = readline()
    if (line.length == 0) {
      print("exiting")
      break
    }

    _buffer += line
    if (is_compilable(_buffer)) {
      var value = null
      try {
        value = eval(_buffer)
        _ = value
        if (value) {
          print(value)
        }
      } catch(error) {
        print("ERROR: " + error)
      }
      _buffer = ''
    }
  }
}

print("Welcome to couchsh")
_mainloop()

