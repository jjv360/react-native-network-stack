
import { NativeModules, NativeEventEmitter } from 'react-native'
import Socket from './Socket'

/** Handles connection to a remote TCP socket and sending/receiving data. */
export default class TCPSocket extends Socket {

    /** Constructor */
    constructor(info) {
        super(info)

        // List of promises to reject if the connection closes
        this.pendingPromises = []

    }

    /** 
     * Connect to a remote socket.
     * 
     * @param {string} host Hostname or IP address
     * @param {int} port Port number
     * @returns {Promise<TCPSocket>} The connected socket.
     */
    static async connect(host, port) {

        // Create native socket, get it's ID
        let info = await NativeModules.RNNetworkStack.tcpConnect(host, port)

        // Create new instance
        return new TCPSocket(info)

    }

    /**
     * Listen for incoming connections on the specified port.
     * 
     * @param {int} port The port to listen on. Pass 0 to pick a random port.
     * @param {string} host The IP address of the interface to listen on. Pass '0.0.0.0' for all interfaces.
     */
    static async listen(port = 0, host = '0.0.0.0') {

        // Create native socket, get it's ID
        let info = await NativeModules.RNNetworkStack.tcpListen(host, port)

        // Create new instance
        let socket = new TCPSocket(info)
        socket.isServer = true

        // Done
        return socket

    }

    /**
     * Reads data from the socket. The options object can contain these keys:
     * - `until` : _(string)_ Reads data until the specified termination is found.
     * - `length` : _(int)_ Reads data until the specified number of bytes have been read.
     * - `saveTo` : _(string)_ Write the data to the specified file path, instead of returning it.
     * - `skip` : _(boolean)_ If true, the data will be skipped instead of being returned.
     * - `type` : _(string)_ Defaults to 'utf8'. One of: `utf8`, `buffer`
     * - `onProgress` : _(function(int))_ Called every so often with the amount of bytes transferred
     * 
     * @param {Object} opts Options object.
     * @returns {Promise<string>} The read data 
     */
    async read(opts = {}) {

        // Check if server
        if (this.isServer)
            throw new Error("This is a server socket. You can't use read() or write() on it.")

        // Check if user wants progress events. NOTE: This weirdness is due to React Native's inability to have 
        // multiple callbacks in a native API call.
        let eventID = null
        let eventSubscription = null
        if (opts.onProgress) {

            // Get event ID
            if (!TCPSocket.nextEventID) TCPSocket.nextEventID = 1
            eventID = "" + (TCPSocket.nextEventID++)

            // Add listener
            eventSubscription = Socket.emitter.addListener('net.read', str => {

                // Check if ours
                let args = str.split('|')
                if (args[0] != eventID)
                    return

                // Convert to progress and send it
                opts.onProgress(parseInt(args[1]))

            })

        }

        // Pass request to native lib
        let outType = opts.saveTo ? 'save' : opts.skip ? 'skip' : opts.type || 'utf8'
        let out = await NativeModules.RNNetworkStack.tcpRead(
            this.id, 
            opts.until, 
            typeof opts.length == 'number' ? opts.length : -1,
            opts.saveTo,
            outType,
            eventID || ""
        ).then(val => {

            // Remove listener if needed
            if (eventSubscription)
                eventSubscription.remove()

            // Pass on data
            return val

        }).catch(err => {

            // Remove listener if needed
            if (eventSubscription)
                eventSubscription.remove()

            // Pass on error
            throw err

        })

        // Check output type
        if (outType == 'skip') {

            // Nothing returned
            return null

        } else if (outType == 'save') {

            // Nothing returned since data was saved to a file
            return null

        } else if (outType == 'utf8') {

            // Return data as-is
            return out

        } else if (outType == 'buffer') {

            // Convert base64 to a buffer
            return Buffer.from(out, 'base64')

        } else {

            // Unknown data type
            throw new Error("Unknown data type: " + outType)

        }

    }

    /**
     * Writes data to the socket.
     * 
     * @param {string|int|Blob} data Data to send. Can be a single byte, a UTF8 string, or a Blob.
     * @param {Object} opts Options object.
     * @param {boolean} opts.file If true, `data` contains the path to a file. The contents of the file will be sent over the socket.
     * @param {function} opts.onProgress Called every so often with the amount of bytes transferred. Only applies to `file` transfers.
     * @returns {Promise} A promise which resolves once the data has been sent
     */
    async write(data, opts = {}) {

        // Check if server
        if (this.isServer)
            throw new Error("This is a server socket. You can't use read() or write() on it.")

        // Check if user wants progress events. NOTE: This weirdness is due to React Native's inability to have 
        // multiple callbacks in a native API call.
        let eventID = null
        let eventSubscription = null
        if (opts.onProgress) {

            // Get event ID
            if (!TCPSocket.nextEventID) TCPSocket.nextEventID = 1
            eventID = "" + (TCPSocket.nextEventID++)

            // Add listener
            eventSubscription = Socket.emitter.addListener('net.write', str => {

                // Check if ours
                let args = str.split('|')
                if (args[0] != eventID)
                    return

                // Convert to progress and send it
                opts.onProgress(parseInt(args[1]))

            })

        }

        // HACK: Create a promise which is resolved when either the write completes, or the connection is closed.
        // For some reason on Android a write() with a large amount of data can block, and it doesn't unblock if 
        // the remote connection is lost for a _long_ time.
        let promiseObj = null
        let promise = new Promise((resolve, reject) => {
            promiseObj = { resolve, reject}
        })

        // Store promise
        this.pendingPromises.push(promiseObj)

        // Get data type
        let dataType = 'utf8'
        if (opts.file) {
            
            // Data is a single byte
            dataType = 'file'

        } else if (data === null || data === undefined) {
            
            // No data provided
            throw new Error("No data provided to send.")

        } else if (typeof data == 'number') {
            
            // Data is a single byte
            dataType = 'byte'

        } else if (typeof data == 'string') {

            // Data is a UTF8 string
            dataType = 'utf8'

        } else if (data instanceof Blob) {

            // Data is a Blob
            dataType = 'base64'

            // Decode the blob into a Base64 string
            // TODO: This is nasty AF, find a better way of passing binary data around
            let filereader = new FileReader()
            filereader.readAsDataURL(data)
            let dataURL = await new Promise((resolve, reject) => {
                filereader.onload = e => {
                    if (filereader.error) reject(filereader.error)
                    else resolve(filereader.result)
                }
            })

            // Extract just the base64 data
            data = dataURL.substr(dataURL.indexOf('base64,') + 7)

        } else if (data instanceof ArrayBuffer) {

            // Data is an ArrayBuffer
            dataType = 'base64'

            // Decode the blob into a Base64 string
            // TODO: This is nasty AF, find a better way of passing binary data around
            data = Buffer.from(data).toString('base64')

        } else if (typeof data == 'object') {

            // Data is a UTF8-encoded JSON object
            dataType = 'utf8'
            data = JSON.stringify(data)

        } else {

            // Unknown data type
            throw new Error("Unknown data type provided.")

        }

        // Pass request to native lib
        NativeModules.RNNetworkStack.tcpWrite(
            this.id, 
            data, 
            dataType,
            eventID
        ).then(val => {

            // Remove listener if needed
            if (eventSubscription)
                eventSubscription.remove()

            // Pass on data
            promiseObj.resolve(val)
            this.pendingPromises = this.pendingPromises.filter(o => o != promiseObj)

        }).catch(err => {

            // Remove listener if needed
            if (eventSubscription)
                eventSubscription.remove()

            // Pass on error
            promiseObj.reject(err)
            this.pendingPromises = this.pendingPromises.filter(o => o != promiseObj)

        })

        // Wait for promise
        return promise

    }

    /**
     * Accept an incoming connection socket. This will block until a connection is received, or
     * until the socket is closed.
     * 
     * @returns {Promise<TCPSocket>} The new connection.
     */
    async accept() {

        // Check if server
        if (!this.isServer)
            throw new Error("This is not a server socket. You can't use accept() on it.")

        // Create native socket, get it's ID
        let info = await NativeModules.RNNetworkStack.tcpAccept(this.id)

        // Create new instance
        let socket = new TCPSocket(info)
        socket.serverSocket = this

        // Done
        return socket

    }

    /** Close the socket */
    close() {
        super.close()

        // Reject pending promises
        for (let promiseObj of this.pendingPromises)
            promiseObj.reject(new Error('The connection was closed.'))
        
        this.pendingPromises = []

    }

}