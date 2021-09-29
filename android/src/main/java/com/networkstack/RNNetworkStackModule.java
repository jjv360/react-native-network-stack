
package com.networkstack;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Dynamic;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableType;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;
import com.facebook.react.modules.core.RCTNativeAppEventEmitter;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.InetAddress;
import java.net.MulticastSocket;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.HashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.apache.commons.codec.binary.Base64;

/**
 * Interface to the JavaScript code.
 */
public class RNNetworkStackModule extends ReactContextBaseJavaModule {

    // Socket info
    class SocketInfo {
        Socket socket;
        ServerSocket server;
        MulticastSocket udpSocket;
        ExecutorService readThread = Executors.newSingleThreadExecutor();
        ExecutorService writeThread = Executors.newSingleThreadExecutor();
    }

    // React context
    private final ReactApplicationContext reactContext;

    // Details of active sockets
    private final HashMap<Integer, SocketInfo> socketInfo = new HashMap<>();
    private static int nextSocketID = 0;

    public RNNetworkStackModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
    }

    @Override
    public String getName() {
        return "RNNetworkStack";
    }

    @Override
    public void onCatalystInstanceDestroy() {
        super.onCatalystInstanceDestroy();

        // Remove all current sockets
        synchronized (socketInfo) {
            for (Integer key : socketInfo.keySet()) {
                socketClose(key, null);
            }
        }

    }

    // Connects to a remote socket
    @ReactMethod public void tcpConnect(final String host, final int port, final Promise promise) {

        // Create socket info
        final SocketInfo si = new SocketInfo();

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Create socket
                    si.socket = new Socket(host, port);

                    // Store it and return ID
                    synchronized (socketInfo) {

                        // Store it
                        int id = nextSocketID++;
                        socketInfo.put(id, si);

                        // Create and return info
                        WritableMap map = Arguments.createMap();
                        map.putInt("id", id);
                        map.putInt("localPort", si.socket.getLocalPort());
                        map.putInt("remotePort", si.socket.getPort());
                        map.putString("localAddress", si.socket.getLocalAddress().getHostAddress());
                        map.putString("remoteAddress", si.socket.getInetAddress().getHostAddress());
                        promise.resolve(map);

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Reads data from the socket
    @ReactMethod public void tcpRead(final int id,
                                     final Dynamic terminator,
                                     final int maxLength,
                                     final String saveTo,
                                     final String outType,
                                     final String progressID,
                                     final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-closed", "This socket is closed.");
            return;
        }

        // Get event emitter
        final DeviceEventManagerModule.RCTDeviceEventEmitter emitter = reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class);

        // Start a background operation
        si.readThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Check if still connected
                    if (si.socket == null)
                        throw new Exception("This socket is not connected.");

                    // Create output stream, depending on where the user wants to send the data
                    OutputStream output;
                    if (saveTo != null && !saveTo.isEmpty()) {

                        // User wants to write output to a file, create the output stream
                        File f = new File(saveTo);
                        output = new FileOutputStream(f);

                    } else {

                        // User wants the data
                        output = new ByteArrayOutputStream();

                    }

                    // Check how the data should be read
                    byte[] outputBuffer;
                    if (maxLength > -1) {

                        // Read specified amount of data
                        long lastUpdateTime = System.currentTimeMillis();
                        int amountRead = 0;
                        byte[] arr = new byte[1024*512];
                        while (amountRead < maxLength) {

                            // Read some data
                            int len = Math.min(arr.length, maxLength - amountRead);
                            len = si.socket.getInputStream().read(arr, 0, len);
                            if (len == -1)
                                throw new Exception("Socket closed before all data could be read.");

                            // Store it
                            output.write(arr, 0, len);
                            amountRead += len;

                            // Notify listener if needed
                            if (progressID != null && lastUpdateTime + 500 < System.currentTimeMillis()) {
                                lastUpdateTime = System.currentTimeMillis();
                                emitter.emit("net.read", progressID + "|" + amountRead);
                            }

                        }

                    } else if (terminator != null && terminator.getType() != ReadableType.Null) {

                        // User wants to read data until the specified terminator is found, convert terminator type to a byte array
                        byte[] terminatorData;
                        if (terminator.getType() == ReadableType.Number) {

                            // Terminator is a byte
                            int num = terminator.asInt();
                            if (num > 255)
                                throw new Exception("The byte specified as the terminator was too big.");

                            terminatorData = new byte[1];
                            terminatorData[0] = (byte) num;

                        } else if (terminator.getType() == ReadableType.String) {

                            // Terminator is a string, get UTF8 encoding
                            terminatorData = terminator.asString().getBytes("UTF-8");

                        } else {

                            // Unknown type!
                            throw new Exception("Unknown data type for 'until' parameter. Please specify a string or a byte.");

                        }

                        // Ensure we have some bytes in the terminator data
                        if (terminatorData.length == 0)
                            throw new Exception("Terminator was empty!");

                        // Read char by char until we have the desired terminator
                        int amountRead = 0;
                        int lastTerminatorMatch = 0;
                        long lastUpdateTime = System.currentTimeMillis();
                        while (true) {

                            // Read byte
                            int b = si.socket.getInputStream().read();
                            if (b == -1)
                                throw new Exception("Socket closed before all data could be read.");

                            // Check if this one matches our next desired terminator byte
                            if (terminatorData[lastTerminatorMatch] == b) {

                                // It does match, increase terminator index
                                lastTerminatorMatch += 1;
                                amountRead += 1;

                                // If all terminator bytes have been matched, stop
                                if (lastTerminatorMatch >= terminatorData.length)
                                    break;

                            } else {

                                // No match, put this char into main buffer
                                output.write(b);
                                amountRead += 1;

                                // Put any items we thought were part of the terminator, into the main buffer
                                for (int i = 0 ; i < lastTerminatorMatch ; i++)
                                    output.write(terminatorData[i]);

                                // Reset count
                                amountRead += lastTerminatorMatch;
                                lastTerminatorMatch = 0;

                            }

                            // Notify listener if needed
                            if (progressID != null && lastUpdateTime + 500 < System.currentTimeMillis()) {
                                lastUpdateTime = System.currentTimeMillis();
                                emitter.emit("net.read", progressID + "|" + amountRead);
                            }

                        }

                    } else {

                        // User didn't provide an end point for our data fetch, just fetch the first data that comes
                        byte[] bfr = new byte[1024*512];
                        int len = si.socket.getInputStream().read(bfr);
                        if (len == -1)
                            throw new Exception("Socket closed before any data could be read.");

                        // Put it into the output buffer
                        outputBuffer = new byte[len];
                        System.arraycopy(bfr, 0, outputBuffer, 0, len);

                    }

                    // Check how the user wants the output
                    if (outType.equals("skip") || outType.equals("save")) {

                        // Done
                        promise.resolve(null);
                        return;

                    } else if (outType.equals("utf8")) {

                        // User wants UTF-8 encoded text
                        ByteArrayOutputStream buffer = (ByteArrayOutputStream) output;
                        promise.resolve(buffer.toString("UTF-8"));

                    } else if (outType.equals("buffer") || outType.equals("base64")) {

                        // User wants Base64 encoded text
                        ByteArrayOutputStream buffer = (ByteArrayOutputStream) output;
                        byte[] bytes = buffer.toByteArray();
                        String base64str = Base64.encodeBase64String(bytes);
                        promise.resolve(base64str);

                    } else {

                        // Can't figure out what type of data the user wants
                        throw new Exception("Unknown encoding type requested.");

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Writes data to the socket
    @ReactMethod public void tcpWrite(final int id,
                                      final Dynamic data,
                                      final String dataType,
                                      final String progressID,
                                      final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-closed", "This socket is closed.");
            return;
        }

        // Get event emitter
        final DeviceEventManagerModule.RCTDeviceEventEmitter emitter = reactContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class);

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Check data type
                    if (dataType.equals("file")) {

                        // User wants to stream the specified file. Open it now.
                        File file = new File(data.asString());
                        FileInputStream fis = new FileInputStream(file);

                        // Start streaming it
                        long lastUpdateTime = System.currentTimeMillis();
                        int amountRead = 0;
                        byte[] buffer = new byte[1024*512];
                        while (true) {

                            // Read some data
                            int amt = fis.read(buffer);
                            if (amt == -1)
                                break;

                            // Write to socket
                            si.socket.getOutputStream().write(buffer, 0, amt);
                            amountRead += amt;

                            // Notify listener if needed
                            if (progressID != null && lastUpdateTime + 500 < System.currentTimeMillis()) {
                                lastUpdateTime = System.currentTimeMillis();
                                emitter.emit("net.write", progressID + "|" + amountRead);
                            }

                        }

                    } else if (dataType.equals("byte")) {

                        // User wants to send a single byte, check byte
                        int num = data.asInt();
                        if (num > 255)
                            throw new Exception("The byte specified was too big.");

                        // Send it
                        si.socket.getOutputStream().write(num);

                    } else if (dataType.equals("utf8")) {

                        // User wants to send a string, convert to UTF-8 and send it
                        byte[] bytes = data.asString().getBytes("UTF-8");
                        si.socket.getOutputStream().write(bytes);

                    } else if (dataType.equals("base64")) {

                        // User wants to send a binary payload that's in base64 format. Convert to data
                        byte[] bytes = Base64.decodeBase64(data.asString().getBytes("UTF-8"));

                        // Write it
                        si.socket.getOutputStream().write(bytes);

                    } else {

                        // Unknown data type!
                        throw new Exception("Unknown data type specified.");

                    }

                    // Done
                    promise.resolve(null);

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Closes the socket
    @ReactMethod public void socketClose(final int id,
                                         final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            if (promise != null)
                promise.resolve(null);
            return;
        }

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Close socket
                    if (si.socket != null && !si.socket.isClosed())
                        si.socket.close();

                    // Close server socket
                    if (si.server != null && !si.server.isClosed())
                        si.server.close();

                    // Close UDP socket
                    if (si.udpSocket != null && !si.udpSocket.isClosed())
                        si.udpSocket.close();

                    // Remove it
                    synchronized (socketInfo) {
                        socketInfo.remove(id);
                    }

                    // Done
                    if (promise != null)
                        promise.resolve(null);

                } catch (Exception e) {

                    // Report error
                    if (promise != null)
                        promise.reject(e);

                }

            }
        });

    }

    // Create a new server socket that listens on the specified port
    @ReactMethod public void tcpListen(final String host, final int port, final Promise promise) {

        // Create socket info
        final SocketInfo si = new SocketInfo();

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Create socket
                    si.server = new ServerSocket(port, 10, InetAddress.getByName(host));

                    // Store it and return ID
                    synchronized (socketInfo) {

                        // Store it
                        int id = nextSocketID++;
                        socketInfo.put(id, si);

                        // Create and return info
                        WritableMap map = Arguments.createMap();
                        map.putInt("id", id);
                        map.putInt("localPort", si.server.getLocalPort());
                        map.putString("localAddress", si.server.getInetAddress().getHostAddress());
                        promise.resolve(map);

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Accept an incoming connection
    @ReactMethod public void tcpAccept(final int id, final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-closed", "This socket has been closed.");
            return;
        }

        // Start a background operation
        si.readThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Create new socket info
                    SocketInfo si2 = new SocketInfo();

                    // Get new socket
                    si2.socket = si.server.accept();
                    if (si2.socket == null)
                        throw new Exception("No incoming connection found.");

                    // Store it and return ID
                    synchronized (socketInfo) {

                        // Store it
                        int id = nextSocketID++;
                        socketInfo.put(id, si2);

                        // Create and return info
                        WritableMap map = Arguments.createMap();
                        map.putInt("id", id);
                        map.putInt("localPort", si2.socket.getLocalPort());
                        map.putInt("remotePort", si2.socket.getPort());
                        map.putString("localAddress", si2.socket.getLocalAddress().getHostAddress());
                        map.putString("remoteAddress", si2.socket.getInetAddress().getHostAddress());
                        promise.resolve(map);

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Create a new UDP socket that binds to the specified port
    @ReactMethod public void udpBind(final int port,
                                     final boolean broadcast,
                                     final boolean reuse,
                                     final Promise promise) {

        // Create socket info
        final SocketInfo si = new SocketInfo();

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Create socket
                    si.udpSocket = new MulticastSocket(port);

                    // Set params
                    if (broadcast) si.udpSocket.setBroadcast(true);
                    if (reuse) si.udpSocket.setReuseAddress(true);

                    // Store it and return ID
                    synchronized (socketInfo) {

                        // Store it
                        int id = nextSocketID++;
                        socketInfo.put(id, si);

                        // Create and return info
                        WritableMap map = Arguments.createMap();
                        map.putInt("id", id);
                        map.putInt("localPort", si.udpSocket.getLocalPort());
                        map.putString("localAddress", si.udpSocket.getLocalAddress().toString());
                        promise.resolve(map);

                    }

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Read a data packet from the UDP socket
    @ReactMethod public void udpRead(final int id,
                                     final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-closed", "This socket has been closed.");
            return;
        }

        // Start a background operation
        si.readThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Read it
                    byte[] buffer = new byte[1024*32];
                    DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                    si.udpSocket.receive(packet);

                    // Convert data to requested format (only UTF8 currently supported)
                    String output = new String(buffer, 0, packet.getLength(), "UTF-8");

                    // Create output info
                    WritableMap map = Arguments.createMap();
                    map.putString("data", output);
                    map.putString("senderAddress", packet.getAddress().getHostAddress());
                    map.putInt("senderPort", packet.getPort());
                    promise.resolve(map);

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Sends a data packet from the UDP socket to a remote device
    @ReactMethod public void udpSend(final int id,
                                     final String address,
                                     final int port,
                                     final String data,
                                     final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-closed", "This socket has been closed.");
            return;
        }

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Convert data
                    byte[] buffer = data.getBytes("UTF-8");

                    // Create packet
                    DatagramPacket packet = new DatagramPacket(buffer, buffer.length, InetAddress.getByName(address), port);

                    // Send the packet
                    si.udpSocket.send(packet);
                    promise.resolve(buffer.length);

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Joins a multicast group
    @ReactMethod public void udpJoin(final int id,
                                     final String address,
                                     final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-closed", "This socket has been closed.");
            return;
        }

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Join the group
                    si.udpSocket.joinGroup(InetAddress.getByName(address));
                    promise.resolve(null);

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

    // Leaves a multicast group
    @ReactMethod public void udpLeave(final int id,
                                      final String address,
                                      final Promise promise) {

        // Get socket info
        final SocketInfo si = socketInfo.get(id);
        if (si == null) {
            promise.reject("socket-closed", "This socket has been closed.");
            return;
        }

        // Start a background operation
        si.writeThread.execute(new Runnable() {
            @Override
            public void run() {

                // Catch errors
                try {

                    // Join the group
                    si.udpSocket.leaveGroup(InetAddress.getByName(address));
                    promise.resolve(null);

                } catch (Exception e) {

                    // Report error
                    promise.reject(e);

                }

            }
        });

    }

}