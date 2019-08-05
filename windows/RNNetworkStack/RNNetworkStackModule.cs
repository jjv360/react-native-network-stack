using ReactNative.Bridge;
using System;
using System.Collections.Generic;
using Windows.ApplicationModel.Core;
using Windows.UI.Core;

namespace Network.Stack.RNNetworkStack
{
    /// <summary>
    /// A module that allows JS to share data.
    /// </summary>
    class RNNetworkStackModule : NativeModuleBase
    {
        /// <summary>
        /// Instantiates the <see cref="RNNetworkStackModule"/>.
        /// </summary>
        internal RNNetworkStackModule()
        {

        }

        /// <summary>
        /// The name of the native module.
        /// </summary>
        public override string Name
        {
            get
            {
                return "RNNetworkStack";
            }
        }

        [ReactMethod] public void tcpListen() {
            
        }

    }
}
