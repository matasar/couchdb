PS1 = 'js> '
PS2 = '..> '
_buffer = ''

Utils = {}
Utils.eachChar = function (string, func) {
    for(i in string) {
        func(string.charAt(i))
    }
}

Utils.map = function(array, func) {
    var results = [];
    for (i in array) {
        results.push(func(array[i]));
    }
    return results;
}

HttpClient = {};
HttpClient.parseResponse = function (response) {
  var r = {}
  var header_index = response.search("\r\n")
  var body_index = response.search("\r\n\r\n")
  var status_line = response.slice(0, header_index)
  var header_lines = response.slice(header_index+2, body_index)
  var body = response.slice(body_index+4, response.length)
  r.status = parseInt(status_line.slice(8,12))
  r.headers = this.parseHeaders(header_lines)
  r.body = body
  return r
}

HttpClient.parseHeaders = function (header_string) {
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

HttpClient.head = function (url) {
    return this.parseResponse(headhttp(url));
}
HttpClient.get = function (url) {
    return this.parseResponse(gethttp(url));
}

HttpClient.put = function(url) {
    return this.parseResponse(puthttp(url));
}

HttpClient.post = function(url) {
    return this.parseResponse(posthttp(url));
}

HttpClient.delete = function(url) {
    return this.parseResponse(delhttp(url));
}

HttpClient.copy = function(url) {
    return this.parseResponse(copyhttp(url));
}


HttpClient.move = function(url) {
    return this.parseResponse(movehttp(url));
}


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
      if (value)
        print(value)
    } catch(error) {
      print("ERROR: " + error)
    }
    _buffer = ''
  }
}
